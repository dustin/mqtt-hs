{-|
Module      : Network.MQTT.Client.
Description : An MQTT client.
Copyright   : (c) Dustin Sallings, 2019
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

An MQTT protocol client

Both
<http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html MQTT 3.1.1>
and
<https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html MQTT 5.0>
are supported over plain TCP, TLS, WebSockets and Secure WebSockets.
-}

{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client (
  -- * Configuring the client.
  MQTTConfig(..), MQTTClient, QoS(..), Topic, mqttConfig,  mkLWT, LastWill(..),
  ProtocolLevel(..), Property(..), SubOptions(..), subOptions, MessageCallback(..),
  -- * Running and waiting for the client.
  waitForClient,
  connectURI, isConnected,
  disconnect, normalDisconnect, stopClient,
  -- * General client interactions.
  subscribe, unsubscribe, publish, publishq, pubAliased,
  svrProps, connACK, MQTTException(..),
  -- * Low-level bits
  runMQTTConduit, MQTTConduit, isConnectedSTM, connACKSTM,
  registerCorrelated, unregisterCorrelated
  ) where

import           Control.Concurrent         (myThreadId, threadDelay)
import           Control.Concurrent.Async   (Async, async, asyncThreadId, cancel, cancelWith, link, race_, wait,
                                             waitAnyCancel)
import           Control.Concurrent.MVar    (MVar, newEmptyMVar, putMVar, takeMVar)
import           Control.Concurrent.STM     (STM, TChan, TVar, atomically, check, modifyTVar', newTChan, newTChanIO,
                                             newTVarIO, orElse, readTChan, readTVar, readTVarIO, registerDelay, retry,
                                             writeTChan, writeTVar)
import           Control.DeepSeq            (force)
import qualified Control.Exception          as E
import           Control.Monad              (forever, guard, join, unless, void, when)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Bifunctor             (first)
import qualified Data.ByteString.Char8      as BCS
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Conduit               (ConduitT, Void, await, runConduit, yield, (.|))
import           Data.Conduit.Attoparsec    (conduitParser)
import qualified Data.Conduit.Combinators   as C
import           Data.Conduit.Network       (AppData, appSink, appSource, clientSettings, runTCPClient)
import           Data.Conduit.Network.TLS   (runTLSClient, tlsClientConfig, tlsClientTLSSettings)
import           Data.Default.Class         (def)
import           Data.Foldable              (traverse_)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import qualified Data.Map.Strict.Decaying   as Decaying
import           Data.Maybe                 (fromJust, fromMaybe)
import           Data.Text                  (Text)
import qualified Data.Text.Lazy             as TL
import qualified Data.Text.Encoding         as TE
import qualified Data.Text.Lazy.Encoding    as TEL
import           Data.Word                  (Word16)
import           GHC.Conc                   (labelThread)
import           Network.Connection         (ConnectionParams (..), TLSSettings (..), connectTo, connectionClose,
                                             connectionGetChunk, connectionPut, initConnectionContext)
import           Network.URI                (URI (..), nullURIAuth, unEscapeString, uriPort, uriRegName, uriUserInfo)
import qualified Network.WebSockets         as WS
import           Network.WebSockets.Stream  (makeStream)
import           System.IO.Error            (catchIOError, isEOFError)
import           System.Timeout             (timeout)

import qualified Data.Set                   as Set
import           Network.MQTT.Topic         (Filter, Topic, mkTopic, unFilter, unTopic)
import           Network.MQTT.Types         as T

data ConnState = Starting
               | Connected
               | Stopped
               | Disconnected
               | DiscoErr DisconnectRequest
               | ConnErr ConnACKFlags deriving (Eq, Show)

data DispatchType = DSubACK | DUnsubACK | DPubACK | DPubREC | DPubREL | DPubCOMP
  deriving (Eq, Show, Ord, Enum, Bounded)


-- | Callback invoked on each incoming subscribed message.
data MessageCallback = NoCallback
  -- | Callbacks will be invoked asynchronously, ordering is likely preserved, but not guaranteed.
  -- In high throughput scenarios, slow callbacks may result in a high number of Haskell threads,
  -- potentially bringing down the entire application when running out of memory.
  -- Typically faster than `OrderedCallback`.
  -- Use 'System.Mem.setAllocationCounter' and 'System.Mem.enableAllocationLimit'
  -- to restrain the unbounded threads memory use.
  -- Use a simple 'System.Timeout.timeout' to restrain unbounded thread runtime.
  | SimpleCallback (MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ())
  -- | Callbacks are guaranteed to be invoked in the same order messages are received.
  -- In high throughput scenarios, slow callbacks may cause the underlying TCP connection to block,
  -- potentially being terminated by the broker.
  -- Typically slower than `SimpleCallback`.
  | OrderedCallback (MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ())
  -- | A LowLevelCallback receives the client and the entire publish request, providing
  -- access to all of the fields of the request.  This is slightly harder to use than
  -- SimpleCallback for common cases, but there are cases where you need all the things.
  | LowLevelCallback (MQTTClient -> PublishRequest -> IO ())
  -- | A low level callback that is ordered.
  | OrderedLowLevelCallback (MQTTClient -> PublishRequest -> IO ())


-- | The MQTT client.
--
-- See 'connectURI' for the most straightforward example.
data MQTTClient = MQTTClient {
  _ch             :: TChan MQTTPkt
  , _pktID        :: TVar Word16
  , _cb           :: MessageCallback
  , _acks         :: TVar (Map (DispatchType,Word16) (TChan MQTTPkt))
  , _inflight     :: Decaying.Map Word16 PublishRequest
  , _st           :: TVar ConnState
  , _ct           :: TVar (Maybe (Async ()))
  , _outA         :: TVar (Map Topic Word16)
  , _inA          :: TVar (Map Word16 Topic)
  , _connACKFlags :: TVar ConnACKFlags
  , _corr         :: Decaying.Map BL.ByteString MessageCallback
  , _cbM          :: MVar (IO ())
  , _cbHandle     :: TVar (Maybe (Async ()))
  }

-- | Configuration for setting up an MQTT client.
data MQTTConfig = MQTTConfig{
  _cleanSession     :: Bool -- ^ False if a session should be reused.
  , _lwt            :: Maybe LastWill -- ^ LastWill message to be sent on client disconnect.
  , _msgCB          :: MessageCallback -- ^ Callback for incoming messages.
  , _protocol       :: ProtocolLevel -- ^ Protocol to use for the connection.
  , _connProps      :: [Property] -- ^ Properties to send to the broker in the CONNECT packet.
  , _hostname       :: String -- ^ Host to connect to (parsed from the URI)
  , _port           :: Int -- ^ Port number (parsed from the URI)
  , _connID         :: String -- ^ Unique connection ID (parsed from the URI)
  , _username       :: Maybe String -- ^ Optional username (parsed from the URI)
  , _password       :: Maybe String -- ^ Optional password (parsed from the URI)
  , _connectTimeout :: Int -- ^ Connection timeout (microseconds)
  , _tlsSettings    :: TLSSettings -- ^ TLS Settings for secure connections
  , _pingPeriod     :: Int -- ^ Time in seconds between pings
  , _pingPatience   :: Int -- ^ Time in seconds for which there must be no incoming packets before the broker is considered dead. Should be more than the ping period plus the maximum expected ping round trip time.
  }

-- | A default 'MQTTConfig'.  A '_connID' /may/ be required depending on
-- your broker (or if you just want an identifiable/resumable
-- connection).  In MQTTv5, an empty connection ID may be sent and the
-- server may assign an identifier for you and return it in the
-- 'PropAssignedClientIdentifier' 'Property'.
mqttConfig :: MQTTConfig
mqttConfig = MQTTConfig{_hostname="", _port=1883, _connID="",
                        _username=Nothing, _password=Nothing,
                        _cleanSession=True, _lwt=Nothing,
                        _msgCB=NoCallback,
                        _protocol=Protocol311, _connProps=mempty,
                        _connectTimeout=180000000,
                        _tlsSettings=def,
                        _pingPeriod=30000000,
                        _pingPatience=90000000}

-- | Connect to an MQTT server by URI.
--
-- @mqtt://@, @mqtts://@, @ws://@, and @wss://@ URLs are supported.
-- The host, port, username, and password will be derived from the URI
-- and the values supplied in the config will be ignored.
--
-- > main :: IO
-- > main = do
-- >   let (Just uri) = parseURI "mqtt://test.mosquitto.org"
-- >   mc <- connectURI mqttConfig{} uri
-- >   publish mc "tmp/topic" "hello!" False
connectURI :: MQTTConfig -> URI -> IO MQTTClient
connectURI cfg@MQTTConfig{..} uri = do
  let cf = case uriScheme uri of
             "mqtt:"  -> runClient
             "mqtts:" -> runClientTLS
             "ws:"    -> runWS uri False
             "wss:"   -> runWS uri True
             us       -> mqttFail $ "invalid URI scheme: " <> us

      a = fromMaybe nullURIAuth $ uriAuthority uri
      (u,p) = up (uriUserInfo a)

  v <- namedTimeout "MQTT connect" _connectTimeout $
    cf cfg{Network.MQTT.Client._connID=cid _protocol (uriFragment uri),
           _hostname=uriRegName a, _port=port (uriPort a) (uriScheme uri),
           Network.MQTT.Client._username=u, Network.MQTT.Client._password=p}

  maybe (mqttFail $ "connection to " <> show uri <> " timed out") pure v

  where
    port "" "mqtt:"  = 1883
    port "" "mqtts:" = 8883
    port "" "ws:"    = 80
    port "" "wss:"   = 443
    port x _         = (read . tail) x

    cid _ ['#']    = ""
    cid _ ('#':xs) = xs
    cid _ _        = ""

    up "" = (_username, _password)
    up x = let (u,r) = break (== ':') (init x) in
             (Just (unEscapeString u), if r == "" then Nothing else Just (unEscapeString $ tail r))


-- | Set up and run a client from the given config.
runClient :: MQTTConfig -> IO MQTTClient
runClient cfg@MQTTConfig{..} = tcpCompat (runTCPClient (clientSettings _port (BCS.pack _hostname))) cfg

-- | Set up and run a client connected via TLS.
runClientTLS :: MQTTConfig -> IO MQTTClient
runClientTLS cfg@MQTTConfig{..} = tcpCompat (runTLSClient tlsConf) cfg
  where tlsConf = (tlsClientConfig _port (BCS.pack _hostname)) {tlsClientTLSSettings=_tlsSettings}

-- Compatibility mechanisms for TCP Conduit bits.
tcpCompat :: ((AppData -> IO ()) -> IO ()) -> MQTTConfig -> IO MQTTClient
tcpCompat mkconn = runMQTTConduit (adapt mkconn)
  where adapt mk f = mk (f . adaptor)
        adaptor ad = (appSource ad, appSink ad)

runWS :: URI -> Bool -> MQTTConfig -> IO MQTTClient
runWS URI{uriPath, uriQuery} secure cfg@MQTTConfig{..} =
  runMQTTConduit (adapt $ cf secure _hostname _port endpoint WS.defaultConnectionOptions hdrs) cfg

  where
    hdrs = [("Sec-WebSocket-Protocol", "mqtt")]
    adapt mk f = mk (f . adaptor)
    adaptor s = (wsSource s, wsSink s)

    endpoint = uriPath <> uriQuery

    cf :: Bool -> String -> Int -> String -> WS.ConnectionOptions -> WS.Headers -> WS.ClientApp () -> IO ()
    cf False = WS.runClientWith
    cf True  = runWSS

    wsSource :: WS.Connection -> ConduitT () BCS.ByteString IO ()
    wsSource ws = forever $ do
      bs <- liftIO $ WS.receiveData ws
      unless (BCS.null bs) $ yield bs

    wsSink :: WS.Connection -> ConduitT BCS.ByteString Void IO ()
    wsSink ws = maybe (pure ()) (\bs -> liftIO (WS.sendBinaryData ws bs) >> wsSink ws) =<< await

    runWSS :: String -> Int -> String -> WS.ConnectionOptions -> WS.Headers -> WS.ClientApp () -> IO ()
    runWSS host port path options hdrs' app = do
      let connectionParams = ConnectionParams
            { connectionHostname = host
            , connectionPort =  toEnum port
            , connectionUseSecure = Just _tlsSettings
            , connectionUseSocks = Nothing
            }

      context <- initConnectionContext
      E.bracket (connectTo context connectionParams) connectionClose
        (\conn -> do
            stream <- makeStream (reader conn) (writer conn)
            WS.runClientWithStream stream host path options hdrs' app)

        where
          reader conn =
            catchIOError (Just <$> connectionGetChunk conn)
            (\e -> if isEOFError e then pure Nothing else E.throwIO e)

          writer conn = maybe (pure ()) (connectionPut conn . BC.toStrict)

mqttFail :: String -> a
mqttFail = E.throw . MQTTException

-- A couple async utilities to get our stuff named.

namedAsync :: String -> IO a -> IO (Async a)
namedAsync s a = async a >>= \p -> labelThread (asyncThreadId p) s >> pure p

namedTimeout :: String -> Int -> IO a -> IO (Maybe a)
namedTimeout n to a = timeout to (myThreadId >>= \tid -> labelThread tid n >> a)

-- | MQTTConduit provides a source and sink for data as used by 'runMQTTConduit'.
type MQTTConduit = (ConduitT () BCS.ByteString IO (), ConduitT BCS.ByteString Void IO ())

-- | Set up and run a client with a conduit context function.
--
-- The provided action calls another IO action with a 'MQTTConduit' as a
-- parameter.  It is expected that this action will manage the
-- lifecycle of the conduit source/sink on behalf of the client.
runMQTTConduit :: ((MQTTConduit -> IO ()) -> IO ()) -- ^ an action providing an 'MQTTConduit' in an execution context
               -> MQTTConfig -- ^ the 'MQTTConfig'
               -> IO MQTTClient
runMQTTConduit mkconn MQTTConfig{..} = do
  _ch <- newTChanIO
  _pktID <- newTVarIO 1
  _acks <- newTVarIO mempty
  _inflight <- Decaying.new 60
  _st <- newTVarIO Starting
  _ct <- newTVarIO Nothing
  _outA <- newTVarIO mempty
  _inA <- newTVarIO mempty
  _connACKFlags <- newTVarIO (ConnACKFlags NewSession ConnUnspecifiedError mempty)
  _corr <- Decaying.new 600
  _cbM <- newEmptyMVar
  _cbHandle <- newTVarIO Nothing
  let _cb = _msgCB
      cli = MQTTClient{..}

  t <- namedAsync "MQTT clientThread" $ clientThread cli
  s <- atomically (waitForLaunch cli t)

  when (s == Disconnected) $ wait t

  atomically $ checkConnected cli

  pure cli

  where
    clientThread cli = E.finally connectAndRun markDisco
      where
        connectAndRun = mkconn $ \ad -> start cli ad >>= run ad
        markDisco = atomically $ do
          st <- readTVar (_st cli)
          guard $ st == Starting || st == Connected
          writeTVar (_st cli) Disconnected

    start c (_,sink) = do
      void . runConduit $ do
        let req = connectRequest{T._connID=BC.pack _connID,
                                 T._lastWill=_lwt,
                                 T._username=TEL.encodeUtf8 . TL.pack <$> _username,
                                 T._password=BC.pack <$> _password,
                                 T._cleanSession=_cleanSession,
                                 T._connProperties=_connProps}
        yield (BL.toStrict $ toByteString _protocol req) .| sink

      pure c

    run (src,sink) c@MQTTClient{..} = do
      pch <- newTChanIO
      o <- namedAsync "MQTT out" $ onceConnected >> processOut
      p <- namedAsync "MQTT ping" $ onceConnected >> doPing
      w <- namedAsync "MQTT watchdog" $ watchdog pch
      s <- namedAsync "MQTT in" $ doSrc pch

      void $ waitAnyCancel [o, p, w, s]

      where
        doSrc pch = runConduit $ src
                    .| conduitParser (parsePacket _protocol)
                    .| C.mapM_ (\(_,x) -> liftIO (dispatch c pch $! x))

        onceConnected = atomically $ check . (== Connected) =<< readTVar _st

        processOut = runConduit $
          C.repeatM (liftIO (atomically $ checkConnected c >> readTChan _ch))
          .| C.map (BL.toStrict . toByteString _protocol)
          .| sink

        doPing = forever $ threadDelay _pingPeriod >> sendPacketIO c PingPkt

        watchdog ch = forever $ do
          toch <- registerDelay _pingPatience
          timedOut <- atomically $ ((check =<< readTVar toch) >> pure True) `orElse` (readTChan ch >> pure False)
          when timedOut $ killConn c Timeout

    waitForLaunch MQTTClient{..} t = do
      writeTVar _ct (Just t)
      c <- readTVar _st
      if c == Starting then retry else pure c

-- | Wait for a client to terminate its connection.
-- An exception is thrown if the client didn't terminate expectedly.
waitForClient :: MQTTClient -> IO ()
waitForClient c@MQTTClient{..} = flip E.finally (stopCallbackThread c) $ do
  void . traverse wait =<< readTVarIO _ct
  maybe (pure ()) E.throwIO =<< atomically (stateX c Stopped)

-- | Stops the client and closes the connection without sending a DISCONNECT
-- message to the broker. This will cause the last-will message to be delivered
-- by the broker if it has been defined.
stopClient :: MQTTClient -> IO ()
stopClient MQTTClient{..} = do
  void . traverse cancel =<< readTVarIO _ct
  void . traverse cancel =<< readTVarIO _cbHandle
  atomically (writeTVar _st Stopped)

stateX :: MQTTClient -> ConnState -> STM (Maybe E.SomeException)
stateX MQTTClient{..} want = f <$> readTVar _st

  where
    je = Just . E.toException . MQTTException

    f :: ConnState -> Maybe E.SomeException
    f Connected    = if want == Connected then Nothing else je "unexpectedly connected"
    f Stopped      = if want == Stopped then Nothing else je "unexpectedly stopped"
    f Disconnected = je "disconnected"
    f Starting     = je "died while starting"
    f (DiscoErr x) = Just . E.toException . Discod $ x
    f (ConnErr e)  = je (show e)

data MQTTException = Timeout | BadData | Discod DisconnectRequest | MQTTException String deriving(Eq, Show)

instance E.Exception MQTTException

dispatch :: MQTTClient -> TChan Bool -> MQTTPkt -> IO ()
dispatch c@MQTTClient{..} pch pkt =
  case pkt of
    (ConnACKPkt p)                            -> connACKd p
    (PublishPkt p)                            -> pub p
    (SubACKPkt (SubscribeResponse i _ _))     -> delegate DSubACK i
    (UnsubACKPkt (UnsubscribeResponse i _ _)) -> delegate DUnsubACK i
    (PubACKPkt (PubACK i _ _))                -> delegate DPubACK i
    (PubRELPkt (PubREL i _ _))                -> pubd i
    (PubRECPkt (PubREC i _ _))                -> delegate DPubREC i
    (PubCOMPPkt (PubCOMP i _ _))              -> delegate DPubCOMP i
    (DisconnectPkt req)                       -> disco req
    PongPkt                                   -> atomically . writeTChan pch $ True

    -- Not implemented
    (AuthPkt p)                               -> mqttFail ("unexpected incoming auth: " <> show p)

    -- Things clients shouldn't see
    PingPkt                                   -> mqttFail "unexpected incoming ping packet"
    (ConnPkt _ _)                             -> mqttFail "unexpected incoming connect"
    (SubscribePkt _)                          -> mqttFail "unexpected incoming subscribe"
    (UnsubscribePkt _)                        -> mqttFail "unexpected incoming unsubscribe"

  where connACKd connr@(ConnACKFlags _ val _) = case val of
                                                  ConnAccepted -> atomically $ do
                                                    writeTVar _connACKFlags connr
                                                    writeTVar _st Connected
                                                  _ -> do
                                                    t <- readTVarIO _ct
                                                    atomically $ writeTVar _st (ConnErr connr)
                                                    maybeCancelWith (MQTTException $ show connr) t

        pub p@PublishRequest{_pubQoS=QoS0} = atomically (resolve p) >>= notify Nothing
        pub p@PublishRequest{_pubQoS=QoS1, _pubPktID} =
          notify (Just (PubACKPkt (PubACK _pubPktID 0 mempty))) =<< atomically (resolve p)
        pub p@PublishRequest{_pubQoS=QoS2} = atomically $ do
          p'@PublishRequest{..} <- resolve p
          Decaying.insert _pubPktID p' _inflight
          sendPacket c (PubRECPkt (PubREC _pubPktID 0 mempty))

        pubd i = atomically (Decaying.updateLookupWithKey (\_ _ -> Nothing) i _inflight) >>= \case
            Nothing -> sendPacketIO c (PubCOMPPkt (PubCOMP i 0x92 mempty))
            Just p  -> notify (Just (PubCOMPPkt (PubCOMP i 0 mempty))) p

        notify rpkt p@PublishRequest{..} = do
          atomically $ Decaying.delete _pubPktID _inflight
          cb <- maybe (pure _cb) (\cd -> atomically (Decaying.findWithDefault _cb cd _corr)) cdata
          E.evaluate . force =<< case cb of
                                   NoCallback                -> pure ()
                                   SimpleCallback f          -> call (f c (blToTopic _pubTopic) _pubBody _pubProps)
                                   OrderedCallback f         -> callOrd (f c (blToTopic _pubTopic) _pubBody _pubProps)
                                   LowLevelCallback f        -> call (f c p)
                                   OrderedLowLevelCallback f -> callOrd (f c p)

            where
              call a = link =<< namedAsync "notifier" (a >> respond)
              callOrd a = putMVar _cbM $ a >> respond
              respond = traverse_ (sendPacketIO c) rpkt
              cdata = foldr f Nothing _pubProps
                where f (PropCorrelationData x) _ = Just x
                      f _ o                       = o

        resolve p@PublishRequest{..} = do
          topic <- resolveTopic (foldr aliasID Nothing _pubProps)
          pure p{_pubTopic=topicToBL topic}

          where
            aliasID (PropTopicAlias x) _ = Just x
            aliasID _ o                  = o

            resolveTopic Nothing = pure (blToTopic _pubTopic)
            resolveTopic (Just x) = do
              when (_pubTopic /= "") $ modifyTVar' _inA (Map.insert x (blToTopic _pubTopic))
              maybe (mqttFail ("failed to lookup topic alias " <> show x)) pure . Map.lookup x =<< readTVar _inA

        delegate dt pid = atomically $
          maybe (nak dt) (`writeTChan` pkt) . Map.lookup (dt, pid) =<< readTVar _acks

            where
              nak DPubREC = sendPacket c (PubRELPkt  (PubREL  pid 0x92 mempty))
              nak _       = pure ()


        disco req = do
          atomically $ writeTVar _st (DiscoErr req)
          maybeCancelWith (Discod req) =<< readTVarIO _ct

-- Run OrderedCallbacks in a background thread. Does nothing for other callback types.
-- We keep the async handle in a TVar and make sure only one of these threads is running.
runCallbackThread :: MQTTClient -> IO ()
runCallbackThread MQTTClient{_cb, _cbM, _cbHandle}
  | isOrdered _cb = do
      -- We always spawn a thread, but may kill it if we already have
      -- one.  The new thread won't start until we atomically confirm
      -- it's the only one.
      latch <- newTVarIO False
      handle <- namedAsync "ordered callbacks" (waitFor latch *> runOrderedCallbacks)
      join . atomically $ do
        cbThread <- readTVar _cbHandle
        case cbThread of
          Nothing -> do
            -- This is the first thread.  Flip the latch and put it in place.
            writeTVar latch True
            writeTVar _cbHandle (Just handle)
            pure (pure ())
          Just _ -> pure (cancel handle) -- otherwise, cancel the temporary thread.
  | otherwise = pure ()
    where isOrdered (OrderedCallback _)         = True
          isOrdered (OrderedLowLevelCallback _) = True
          isOrdered _                           = False
          waitFor latch = atomically (check =<< readTVar latch)
          -- Keep running callbacks from the MVar
          runOrderedCallbacks = forever . join . takeMVar $ _cbM

-- Stop the background thread for OrderedCallbacks. Does nothing for other callback types.
stopCallbackThread :: MQTTClient -> IO ()
stopCallbackThread MQTTClient{_cbHandle} = maybe (pure ()) cancel =<< readTVarIO _cbHandle

maybeCancelWith :: E.Exception e => e -> Maybe (Async ()) -> IO ()
maybeCancelWith e = void . traverse (`cancelWith` e)

killConn :: E.Exception e => MQTTClient -> e -> IO ()
killConn MQTTClient{..} e = readTVarIO _ct >>= maybeCancelWith e

checkConnected :: MQTTClient -> STM ()
checkConnected mc = maybe (pure ()) E.throw =<< stateX mc Connected

-- | True if we're currently in a normally connected state (in the IO monad).
isConnected :: MQTTClient -> IO Bool
isConnected = atomically . isConnectedSTM

-- | True if we're currently in a normally connected state (in the STM monad).
isConnectedSTM :: MQTTClient -> STM Bool
isConnectedSTM MQTTClient{..} = (Connected ==) <$> readTVar _st

sendPacket :: MQTTClient -> MQTTPkt -> STM ()
sendPacket c@MQTTClient{..} p = checkConnected c >> writeTChan _ch p

sendPacketIO :: MQTTClient -> MQTTPkt -> IO ()
sendPacketIO c = atomically . sendPacket c

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

topicToBL :: Topic -> BL.ByteString
topicToBL = textToBL . unTopic

filterToBL :: Filter -> BL.ByteString
filterToBL = textToBL . unFilter

blToTopic :: BL.ByteString -> Topic
blToTopic = fromJust . mkTopic . blToText

reservePktID :: MQTTClient -> [DispatchType] -> STM (TChan MQTTPkt, Word16)
reservePktID c@MQTTClient{..} dts = do
  checkConnected c
  ch <- newTChan
  pid <- readTVar _pktID
  modifyTVar' _pktID $ if pid == maxBound then const 1 else succ
  modifyTVar' _acks (Map.union (Map.fromList [((t, pid), ch) | t <- dts]))
  pure (ch,pid)

releasePktID :: MQTTClient -> (DispatchType,Word16) -> STM ()
releasePktID c@MQTTClient{..} k = checkConnected c >> modifyTVar' _acks (Map.delete k)

releasePktIDs :: MQTTClient -> [(DispatchType,Word16)] -> STM ()
releasePktIDs c@MQTTClient{..} ks = checkConnected c >> modifyTVar' _acks deleteMany
  where deleteMany m = Map.withoutKeys m (Set.fromList ks)

sendAndWait :: MQTTClient -> DispatchType -> (Word16 -> MQTTPkt) -> IO MQTTPkt
sendAndWait c@MQTTClient{..} dt f = do
  (ch,pid) <- atomically $ do
    (ch,pid) <- reservePktID c [dt]
    sendPacket c (f pid)
    pure (ch,pid)

  -- Wait for the response in a separate transaction.
  atomically $ do
    st <- readTVar _st
    when (st /= Connected) $ mqttFail "disconnected waiting for response"
    releasePktID c (dt,pid)
    readTChan ch

-- | Subscribe to a list of topic filters with their respective 'QoS'es.
-- The accepted 'QoS'es are returned in the same order as requested.
subscribe :: MQTTClient -> [(Filter, SubOptions)] -> [Property] -> IO ([Either SubErr QoS], [Property])
subscribe c ls props = do
  runCallbackThread c
  sendAndWait c DSubACK (\pid -> SubscribePkt $ SubscribeRequest pid ls' props) >>= \case
    SubACKPkt (SubscribeResponse _ rs aprops) -> pure (rs, aprops)
    pkt                                       -> mqttFail $ "unexpected response to subscribe: " <> show pkt

  where ls' = map (first filterToBL) ls

-- | Unsubscribe from a list of topic filters.
--
-- In MQTT 3.1.1, there is no body to an unsubscribe response, so it
-- can be ignored.  If this returns, you were unsubscribed.  In MQTT
-- 5, you'll get a list of unsub status values corresponding to your
-- request filters, and whatever properties the server thought you
-- should know about.
unsubscribe :: MQTTClient -> [Filter] -> [Property] -> IO ([UnsubStatus], [Property])
unsubscribe c ls props = do
  (UnsubACKPkt (UnsubscribeResponse _ rsn rprop)) <- sendAndWait c DUnsubACK (\pid -> UnsubscribePkt $ UnsubscribeRequest pid (map filterToBL ls) props)
  pure (rprop, rsn)

-- | Publish a message (QoS 0).
publish :: MQTTClient
        -> Topic         -- ^ Topic
        -> BL.ByteString -- ^ Message body
        -> Bool          -- ^ Retain flag
        -> IO ()
publish c t m r = void $ publishq c t m r QoS0 mempty

-- | Publish a message with the specified QoS and Properties list.
publishq :: MQTTClient
         -> Topic         -- ^ Topic
         -> BL.ByteString -- ^ Message body
         -> Bool          -- ^ Retain flag
         -> QoS           -- ^ QoS
         -> [Property]    -- ^ Properties
         -> IO ()
publishq c t m r q props = do
  (ch,pid) <- atomically $ reservePktID c types
  E.finally (publishAndWait ch pid) (atomically $ releasePktIDs c [(t',pid) | t' <- types])

    where
      types = [DPubACK, DPubREC, DPubCOMP]
      publishAndWait ch pid = do
        sendPacketIO c (pkt pid)
        when (q > QoS0) $ satisfyQoS ch pid

      pkt pid = PublishPkt $ PublishRequest {_pubDup = False,
                                             _pubQoS = q,
                                             _pubPktID = pid,
                                             _pubRetain = r,
                                             _pubTopic = topicToBL t,
                                             _pubBody = m,
                                             _pubProps = props}

      satisfyQoS ch pid
        | q == QoS0 = pure ()
        | q == QoS1 = void $ do
            (PubACKPkt (PubACK _ st pprops)) <- atomically $ checkConnected c >> readTChan ch
            unless (isOK st) $ mqttFail ("qos 1 publish error: " <> show st <> " " <> show pprops)
        | q == QoS2 = waitRec
        | otherwise = error "invalid QoS"

        where
          isOK 0  = True -- success
          isOK 16 = True -- It worked, but nobody cares (no matching subscribers)
          isOK _  = False

          waitRec = atomically (checkConnected c >> readTChan ch) >>= \case
              PubRECPkt (PubREC _ st recprops) -> do
                unless (isOK st) $ mqttFail ("qos 2 REC publish error: " <> show st <> " " <> show recprops)
                sendPacketIO c (PubRELPkt $ PubREL pid 0 mempty)
              PubCOMPPkt (PubCOMP _ st' compprops) ->
                when (st' /= 0) $ mqttFail ("qos 2 COMP publish error: " <> show st' <> " " <> show compprops)
              wtf -> mqttFail ("unexpected packet received in QoS2 publish: " <> show wtf)

-- | Disconnect from the MQTT server.
disconnect :: MQTTClient -> DiscoReason -> [Property] -> IO ()
disconnect c@MQTTClient{..} reason props = race_ getDisconnected orDieTrying
  where
    getDisconnected = do
      sendPacketIO c (DisconnectPkt $ DisconnectRequest reason props)
      void . traverse wait =<< readTVarIO _ct
      atomically $ writeTVar _st Stopped
    orDieTrying = threadDelay 10000000 >> killConn c Timeout

-- | Disconnect with 'DiscoNormalDisconnection' and no properties.
normalDisconnect :: MQTTClient -> IO ()
normalDisconnect c = disconnect c DiscoNormalDisconnection mempty

-- | A convenience method for creating a 'LastWill'.
mkLWT :: Topic -> BL.ByteString -> Bool -> T.LastWill
mkLWT t m r = T.LastWill{
  T._willRetain=r,
  T._willQoS=QoS0,
  T._willTopic = topicToBL t,
  T._willMsg=m,
  T._willProps=mempty
  }

-- | Get the list of properties that were sent from the broker at connect time.
svrProps :: MQTTClient -> IO [Property]
svrProps = fmap p . atomically . connACKSTM
  where p (ConnACKFlags _ _ props) = props

-- | Get the complete connection ACK packet from the beginning of this session.
connACKSTM :: MQTTClient -> STM ConnACKFlags
connACKSTM MQTTClient{_connACKFlags} = readTVar _connACKFlags

-- | Get the complete connection aCK packet from the beginning of this session.
connACK :: MQTTClient -> IO ConnACKFlags
connACK = atomically . connACKSTM

maxAliases :: MQTTClient -> IO Word16
maxAliases = fmap (foldr f 0) . svrProps
  where
    f (PropTopicAliasMaximum n) _ = n
    f _ o                         = o

-- | Publish a message with the specified 'QoS' and 'Property' list.  If
-- possible, use an alias to shorten the message length.  The alias
-- list is managed by the client in a first-come, first-served basis,
-- so if you use this with more properties than the broker allows,
-- only the first N (up to TopicAliasMaximum, as specified by the
-- broker at connect time) will be aliased.
--
-- This is safe to use as a general publish mechanism, as it will
-- default to not aliasing whenver there's not already an alias and we
-- can't create any more.
pubAliased :: MQTTClient
         -> Topic         -- ^ Topic
         -> BL.ByteString -- ^ Message body
         -> Bool          -- ^ Retain flag
         -> QoS           -- ^ QoS
         -> [Property]    -- ^ Properties
         -> IO ()
pubAliased c@MQTTClient{..} t m r q props = do
  x <- maxAliases c
  (t', n) <- alias x
  let np = props <> case n of
                      0 -> mempty
                      _ -> [PropTopicAlias n]
  publishq c t' m r q np

  where
    alias mv = atomically $ do
      as <- readTVar _outA
      let n = toEnum (length as + 1)
          cur = Map.lookup t as
          v = fromMaybe (if n > mv then 0 else n) cur
      when (v > 0) $ writeTVar _outA (Map.insert t v as)
      pure (maybe t (const "") cur, v)

-- | Register a callback handler for a message with the given correlated data identifier.
--
-- This registration will remain in place until unregisterCorrelated is called to remove it.
registerCorrelated :: MQTTClient -> BL.ByteString -> MessageCallback -> STM ()
registerCorrelated MQTTClient{_corr} bs cb = Decaying.insert bs cb _corr

-- | Unregister a callback handler for the given correlated data identifier.
unregisterCorrelated :: MQTTClient -> BL.ByteString -> STM ()
unregisterCorrelated MQTTClient{_corr} bs = Decaying.delete bs _corr
