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

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client (
  -- * Configuring the client.
  MQTTConfig(..), MQTTClient, QoS(..), Topic, mqttConfig,  mkLWT, LastWill(..),
  ProtocolLevel(..), Property(..), SubOptions(..), subOptions, MessageCallback(..),
  -- * Running and waiting for the client.
  waitForClient,
  connectURI, isConnected,
  disconnect, normalDisconnect,
  -- * General client interactions.
  subscribe, unsubscribe, publish, publishq, pubAliased,
  svrProps, MQTTException(..),
  -- * Low-level bits
  runMQTTConduit, MQTTConduit, isConnectedSTM
  ) where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (Async, async, cancel, cancelWith,
                                             link, race_, wait, withAsync)
import           Control.Concurrent.STM     (STM, TChan, TVar, atomically,
                                             modifyTVar', newTChan, newTChanIO,
                                             newTVarIO, readTChan, readTVar,
                                             readTVarIO, retry, writeTChan,
                                             writeTVar)
import           Control.DeepSeq            (force)
import qualified Control.Exception          as E
import           Control.Monad              (forever, guard, void, when)
import           Control.Monad.IO.Class     (liftIO)
import qualified Data.ByteString.Char8      as BCS
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Conduit               (ConduitT, Void, await, runConduit,
                                             yield, (.|))
import           Data.Conduit.Attoparsec    (conduitParser)
import qualified Data.Conduit.Combinators   as C
import           Data.Conduit.Network       (AppData, appSink, appSource,
                                             clientSettings, runTCPClient)
import           Data.Conduit.Network.TLS   (runTLSClient, tlsClientConfig,
                                             tlsClientTLSSettings)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromMaybe)
import           Data.Text                  (Text)
import qualified Data.Text.Encoding         as TE
import           Data.Word                  (Word16)
import           Network.Connection         (TLSSettings (..))
import           Network.URI                (URI (..), unEscapeString, uriPort,
                                             uriRegName, uriUserInfo)
import qualified Network.WebSockets         as WS
import           System.Timeout             (timeout)
import qualified Wuss                       as WSS

import           Network.MQTT.Topic         (Filter, Topic)
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
  | SimpleCallback (MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ())
  | LowLevelCallback (MQTTClient -> PublishRequest -> IO ())

-- | The MQTT client.
--
-- See 'connectURI' for the most straightforward example.
data MQTTClient = MQTTClient {
  _ch         :: TChan MQTTPkt
  , _pktID    :: TVar Word16
  , _cb       :: MessageCallback
  , _ts       :: TVar [Async ()]
  , _acks     :: TVar (Map (DispatchType,Word16) (TChan MQTTPkt))
  , _st       :: TVar ConnState
  , _ct       :: TVar (Async ())
  , _outA     :: TVar (Map Topic Word16)
  , _inA      :: TVar (Map Word16 Topic)
  , _svrProps :: TVar [Property]
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
                        _tlsSettings=TLSSettingsSimple False False False}

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
             us       -> fail $ "invalid URI scheme: " <> us

      (Just a) = uriAuthority uri
      (u,p) = up (uriUserInfo a)

  v <- timeout _connectTimeout $
    cf cfg{Network.MQTT.Client._connID=cid _protocol (uriFragment uri),
           _hostname=uriRegName a, _port=port (uriPort a) (uriScheme uri),
           Network.MQTT.Client._username=u, Network.MQTT.Client._password=p}

  case v of
    Nothing -> mqttFail $ "connection to " <> show uri <> " timed out"
    Just x  -> pure x

  where
    port "" "mqtt:"  = 1883
    port "" "mqtts:" = 8883
    port "" "ws:"    = 80
    port "" "wss:"   = 443
    port x _         = (read . tail) x

    cid _ ['#']    = ""
    cid _ ('#':xs) = xs
    cid _ _        = ""

    up "" = (Nothing, Nothing)
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
runWS uri secure cfg@MQTTConfig{..} = runMQTTConduit (adapt $ cf secure _hostname _port (uriPath uri) WS.defaultConnectionOptions hdrs) cfg
  where
    hdrs = [("Sec-WebSocket-Protocol", "mqtt")]
    adapt mk f = mk (f . adaptor)
    adaptor s = (wsSource s, wsSink s)

    cf False = WS.runClientWith
    cf True  = \h p -> WSS.runSecureClientWith h ((fromInteger . toInteger) p)

    wsSource :: WS.Connection -> ConduitT () BCS.ByteString IO ()
    wsSource ws = loop
      where loop = do
              bs <- liftIO $ WS.receiveData ws
              if BCS.null bs then pure () else yield bs >> loop

    wsSink :: WS.Connection -> ConduitT BCS.ByteString Void IO ()
    wsSink ws = loop
      where
        loop = await >>= maybe (pure ()) (\bs -> liftIO (WS.sendBinaryData ws bs) >> loop)


pingPeriod :: Int
pingPeriod = 30000000 -- 30 seconds

mqttFail :: String -> a
mqttFail = E.throw . MQTTException

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
  _ts <- newTVarIO []
  _acks <- newTVarIO mempty
  _st <- newTVarIO Starting
  _ct <- newTVarIO undefined
  _outA <- newTVarIO mempty
  _inA <- newTVarIO mempty
  _svrProps <- newTVarIO mempty
  let _cb = _msgCB
      cli = MQTTClient{..}

  t <- async $ clientThread cli
  s <- atomically (waitForLaunch cli t)

  when (s == Disconnected) $ wait t

  atomically $ checkConnected cli

  pure cli

  where
    clientThread cli = E.finally connectAndRun markDisco
      where
        connectAndRun = mkconn $ \ad ->
          E.bracket (start cli ad) cancelAll (run ad)
        markDisco = atomically $ do
          st <- readTVar (_st cli)
          guard $ st == Starting || st == Connected
          writeTVar (_st cli) Disconnected

    start c@MQTTClient{..} (_,sink) = do
      void . runConduit $ do
        let req = connectRequest{T._connID=BC.pack _connID,
                                 T._lastWill=_lwt,
                                 T._username=BC.pack <$> _username,
                                 T._password=BC.pack <$> _password,
                                 T._cleanSession=_cleanSession,
                                 T._properties=_connProps}
        yield (BL.toStrict $ toByteString _protocol req) .| sink

      pure c

    run (src,sink) c@MQTTClient{..} = do
      o <- async $ whenConnected >> processOut
      pch <- newTChanIO
      p <- async $ whenConnected >> doPing
      to <- async (watchdog pch)
      link to

      atomically $ modifyTVar' _ts (\l -> o:p:to:l)

      runConduit $ src
        .| conduitParser (parsePacket _protocol)
        .| C.mapM_ (\(_,x) -> liftIO (dispatch c pch x))

      where
        whenConnected = atomically $ do
          s <- readTVar _st
          if s /= Connected then retry else pure ()

        processOut = runConduit $
          C.repeatM (liftIO (atomically $ checkConnected c >> readTChan _ch))
          .| C.map (BL.toStrict . toByteString _protocol)
          .| sink

        doPing = forever $ threadDelay pingPeriod >> sendPacketIO c PingPkt

        watchdog ch = do
          r <- timeout (pingPeriod * 3) w
          case r of
            Nothing -> killConn c Timeout
            Just _  -> watchdog ch

            where w = atomically . readTChan $ ch

    waitForLaunch MQTTClient{..} t = do
      writeTVar _ct t
      c <- readTVar _st
      if c == Starting then retry else pure c

    cancelAll MQTTClient{..} = mapM_ cancel =<< readTVarIO _ts

-- | Wait for a client to terminate its connection.
-- An exception is thrown if the client didn't terminate expectedly.
waitForClient :: MQTTClient -> IO ()
waitForClient c@MQTTClient{..} = do
  wait =<< readTVarIO _ct
  e <- atomically $ stateX c Stopped
  case e of
    Nothing -> pure ()
    Just x  -> E.throwIO x

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
    (PublishPkt p)                            -> void $ async (pubMachine p) >>= link
    (SubACKPkt (SubscribeResponse i _ _))     -> delegate DSubACK i
    (UnsubACKPkt (UnsubscribeResponse i _ _)) -> delegate DUnsubACK i
    (PubACKPkt (PubACK i _ _))                -> delegate DPubACK i
    (PubRECPkt (PubREC i _ _))                -> delegate DPubREC i
    (PubRELPkt (PubREL i _ _))                -> delegate DPubREL i
    (PubCOMPPkt (PubCOMP i _ _))              -> delegate DPubCOMP i
    (DisconnectPkt req)                       -> disco req
    PongPkt                                   -> atomically . writeTChan pch $ True
    x                                         -> print x

  where connACKd connr@(ConnACKFlags _ val props) = case val of
                                                      ConnAccepted -> atomically $ do
                                                        writeTVar _svrProps props
                                                        writeTVar _st Connected
                                                      _ -> do
                                                        t <- readTVarIO _ct
                                                        atomically $ writeTVar _st (ConnErr connr)
                                                        cancelWith t (MQTTException $ show connr)

        delegate dt pid = atomically $ do
          m <- readTVar _acks
          case Map.lookup (dt, pid) m of
            Nothing -> nak dt
            Just ch -> writeTChan ch pkt

            where
              nak DPubREC = sendPacket c (PubRELPkt  (PubREL  pid 0x92 mempty))
              nak DPubREL = sendPacket c (PubCOMPPkt (PubCOMP pid 0x92 mempty))
              nak _       = pure ()


        disco req = do
          t <- readTVarIO _ct
          atomically $ writeTVar _st (DiscoErr req)
          cancelWith t (Discod req)

        pubMachine pr@PublishRequest{..}
          | _pubQoS == QoS2 = manageQoS2
          | _pubQoS == QoS1 = notify >> sendPacketIO c (PubACKPkt (PubACK _pubPktID 0 mempty))
          | otherwise = notify

          where
            notify = do
              topic <- resolveTopic (foldr aliasID Nothing _pubProps)
              E.evaluate . force =<< case _cb of
                                       NoCallback         -> pure ()
                                       SimpleCallback f   -> f c topic _pubBody _pubProps
                                       LowLevelCallback f -> f c pr{_pubTopic=textToBL topic}

            resolveTopic Nothing = pure (blToText _pubTopic)
            resolveTopic (Just x) = do
              when (_pubTopic /= "") $ atomically $ modifyTVar' _inA (Map.insert x (blToText _pubTopic))
              m <- readTVarIO _inA
              pure (m Map.! x)

            aliasID (PropTopicAlias x) _ = Just x
            aliasID _ o                  = o

            manageQoS2 = do
              ch <- newTChanIO
              atomically $ modifyTVar' _acks (Map.insert (DPubREL, _pubPktID) ch)
              E.finally (manageQoS2' ch) (atomically $ releasePktID c (DPubREL, _pubPktID))
                where
                  sendREC ch = do
                    sendPacketIO c (PubRECPkt (PubREC _pubPktID 0 mempty))
                    (PubRELPkt _) <- atomically $ readTChan ch
                    pure ()

                  manageQoS2' ch = do
                    v <- timeout 10000000 (sendREC ch)
                    case v of
                      Nothing -> killConn c Timeout
                      _ -> notify >> sendPacketIO c (PubCOMPPkt (PubCOMP _pubPktID 0 mempty))

killConn :: E.Exception e => MQTTClient -> e -> IO ()
killConn MQTTClient{..} e = readTVarIO _ct >>= \t -> cancelWith t e

checkConnected :: MQTTClient -> STM ()
checkConnected mc = do
  e <- stateX mc Connected
  case e of
    Nothing -> pure ()
    Just x  -> E.throw x

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
  where deleteMany m = foldr Map.delete m ks

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
subscribe c@MQTTClient{..} ls props = do
  r <- sendAndWait c DSubACK (\pid -> SubscribePkt $ SubscribeRequest pid ls' props)
  let (SubACKPkt (SubscribeResponse _ rs aprops)) = r
  pure (rs, aprops)

    where ls' = map (\(s, i) -> (textToBL s, i)) ls

-- | Unsubscribe from a list of topic filters.
--
-- In MQTT 3.1.1, there is no body to an unsubscribe response, so it
-- can be ignored.  If this returns, you were unsubscribed.  In MQTT
-- 5, you'll get a list of unsub status values corresponding to your
-- request filters, and whatever properties the server thought you
-- should know about.
unsubscribe :: MQTTClient -> [Filter] -> [Property] -> IO ([UnsubStatus], [Property])
unsubscribe c@MQTTClient{..} ls props = do
  (UnsubACKPkt (UnsubscribeResponse _ rsn rprop)) <- sendAndWait c DUnsubACK (\pid -> UnsubscribePkt $ UnsubscribeRequest pid (map textToBL ls) props)
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
  E.finally (publishAndWait ch pid q) (atomically $ releasePktIDs c [(t',pid) | t' <- types])

    where
      types = [DPubACK, DPubREC, DPubCOMP]
      publishAndWait _ pid QoS0 = sendPacketIO c (pkt False pid)
      publishAndWait ch pid _   = withAsync (pub False pid) (\p -> satisfyQoS p ch pid)

      pub dup pid = do
        sendPacketIO c (pkt dup pid)
        threadDelay 5000000
        pub True pid

      pkt dup pid = PublishPkt $ PublishRequest {_pubDup = dup,
                                                 _pubQoS = q,
                                                 _pubPktID = pid,
                                                 _pubRetain = r,
                                                 _pubTopic = textToBL t,
                                                 _pubBody = m,
                                                 _pubProps = props}

      satisfyQoS p ch pid
        | q == QoS0 = pure ()
        | q == QoS1 = void $ do
            (PubACKPkt (PubACK _ st pprops)) <- atomically $ readTChan ch
            when (st /= 0) $ mqttFail ("qos 1 publish error: " <> show st <> " " <> show pprops)
        | q == QoS2 = waitRec
        | otherwise = error "invalid QoS"

        where
          waitRec = do
            rpkt <- atomically $ readTChan ch
            case rpkt of
              PubRECPkt (PubREC _ st recprops) -> do
                when (st /= 0) $ mqttFail ("qos 2 REC publish error: " <> show st <> " " <> show recprops)
                sendPacketIO c (PubRELPkt $ PubREL pid 0 mempty)
                cancel p -- must not publish after rel
              PubCOMPPkt (PubCOMP _ st' compprops) ->
                when (st' /= 0) $ mqttFail ("qos 2 COMP publish error: " <> show st' <> " " <> show compprops)
              wtf -> mqttFail ("unexpected packet received in QoS2 publish: " <> show wtf)

-- | Disconnect from the MQTT server.
disconnect :: MQTTClient -> DiscoReason -> [Property] -> IO ()
disconnect c@MQTTClient{..} reason props = race_ getDisconnected orDieTrying
  where
    getDisconnected = do
      sendPacketIO c (DisconnectPkt $ DisconnectRequest reason props)
      wait =<< readTVarIO _ct
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
  T._willTopic = textToBL t,
  T._willMsg=m,
  T._willProps=mempty
  }

-- | Get the list of properties that were sent from the broker at connect time.
svrProps :: MQTTClient -> IO [Property]
svrProps MQTTClient{..} = readTVarIO _svrProps

maxAliases :: MQTTClient -> IO Word16
maxAliases MQTTClient{..} = foldr f 0 <$> readTVarIO _svrProps
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
