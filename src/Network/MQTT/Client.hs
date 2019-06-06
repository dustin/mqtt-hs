{-|
Module      : Network.MQTT.Client.
Description : An MQTT client.
Copyright   : (c) Dustin Sallings, 2019
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

An MQTT protocol client, based on the 3.1.1 specification:
<http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html>
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client (
  -- * Configuring the client.
  MQTTConfig(..), MQTTClient, QoS(..), Topic, mqttConfig,  mkLWT, LastWill(..),
  -- * Client connection management
  withClient, withClientTLS, withConnectURI,
  -- ** Waiting for the client
  waitForClient, 
  -- ** Client connection and disconnection
  runClient, runClientTLS, 
  connectURI,
  disconnect,
  -- * General client interactions.
  subscribe, unsubscribe, publish, publishq
  ) where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (Async, async, cancel, cancelWith,
                                             link, race_, wait, waitCatch,
                                             withAsync)
import           Control.Concurrent.STM     (STM, TChan, TVar, atomically,
                                             modifyTVar', newTChan, newTChanIO,
                                             newTVarIO, readTChan, readTVar,
                                             readTVarIO, retry, writeTChan,
                                             writeTVar)
import qualified Control.Exception          as E
import           Control.Monad              (forever, void, when)
import           Control.Monad.IO.Class     (liftIO)
import qualified Data.ByteString.Char8      as BCS
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Conduit               (runConduit, yield, (.|))
import           Data.Conduit.Attoparsec    (conduitParser, sinkParser)
import qualified Data.Conduit.Combinators   as C
import           Data.Conduit.Network       (AppData, appSink, appSource,
                                             clientSettings, runTCPClient)
import           Data.Conduit.Network.TLS   (runTLSClient, tlsClientConfig)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Text                  (Text)
import qualified Data.Text.Encoding         as TE
import           Data.Word                  (Word16)
import           Network.URI                (URI (..), unEscapeString, uriPort,
                                             uriRegName, uriUserInfo)
import           System.Timeout             (timeout)



import           Network.MQTT.Topic         (Filter, Topic)
import           Network.MQTT.Types         as T

data ConnState = Starting | Connected | Disconnected deriving (Eq, Show)

data DispatchType = DSubACK | DUnsubACK | DPubACK | DPubREC | DPubREL | DPubCOMP
  deriving (Eq, Show, Ord, Enum, Bounded)

-- | The MQTT client.
-- A client may be built using either runClient or runClientTLS.  For example:
--
-- @
--   mc <- runClient mqttConfig{}
--   publish mc "some/topic" "some message" False
-- @
--
data MQTTClient = MQTTClient {
  _ch      :: TChan MQTTPkt
  , _pktID :: TVar Word16
  , _cb    :: Maybe (MQTTClient -> Topic -> BL.ByteString -> IO ())
  , _ts    :: TVar [Async ()]
  , _acks  :: TVar (Map (DispatchType,Word16) (TChan MQTTPkt))
  , _st    :: TVar ConnState
  , _ct    :: TVar (Async ())
  }

-- | Configuration for setting up an MQTT client.
data MQTTConfig = MQTTConfig{
  _hostname       :: String -- ^ Host to connect to.
  , _port         :: Int -- ^ Port number.
  , _connID       :: String -- ^ Unique connection ID (required).
  , _username     :: Maybe String -- ^ Optional username.
  , _password     :: Maybe String -- ^ Optional password.
  , _cleanSession :: Bool -- ^ False if a session should be reused.
  , _lwt          :: Maybe LastWill -- ^ LastWill message to be sent on client disconnect.
  , _msgCB        :: Maybe (MQTTClient -> Topic -> BL.ByteString -> IO ()) -- ^ Callback for incoming messages.
  }

-- | A default MQTTConfig.  A _connID /should/ be provided by the client in the returned config,
-- but the defaults should work for testing.
mqttConfig :: MQTTConfig
mqttConfig = MQTTConfig{_hostname="localhost", _port=1883, _connID="haskell-mqtt",
                        _username=Nothing, _password=Nothing,
                        _cleanSession=True, _lwt=Nothing,
                        _msgCB=Nothing}


-- | Connect to an MQTT server by URI.  Currently only mqtt and mqtts
-- URLs are supported.  The host, port, username, and password will be
-- derived from the URI and the values supplied in the config will be
-- ignored.
connectURI :: MQTTConfig -> URI -> IO MQTTClient
connectURI cfg uri = do
  let cf = case uriScheme uri of
             "mqtt:"  -> runClient
             "mqtts:" -> runClientTLS
             us       -> fail $ "invalid URI scheme: " <> us

      (Just a) = uriAuthority uri
      (u,p) = up (uriUserInfo a)

  cf cfg{_hostname=uriRegName a, _port=port (uriPort a) (uriScheme uri),
                Network.MQTT.Client._username=u, Network.MQTT.Client._password=p}

  where
    port "" "mqtt:"  = 1883
    port "" "mqtts:" = 8883
    port x _         = read x

    up "" = (Nothing, Nothing)
    up x = let (u,r) = break (== ':') (init x) in
             (Just (unEscapeString u), if r == "" then Nothing else Just (unEscapeString $ tail r))

-- | Memory 'E.bracket' around 'connectURI' and 'disconnect'
withConnectURI :: MQTTConfig -> URI -> (MQTTClient -> IO c) -> IO c
withConnectURI cfg uri = E.bracket (connectURI cfg uri) disconnect

-- | Memory 'E.bracket' around 'runClient' and 'disconnect'
withClient :: MQTTConfig -> (MQTTClient -> IO c) -> IO c
withClient cfg = E.bracket (runClient cfg) disconnect

-- | Memory 'E.bracket' around 'runClientTLS' and 'disconnect'
withClientTLS :: MQTTConfig -> (MQTTClient -> IO c) -> IO c
withClientTLS cfg = E.bracket (runClientTLS cfg) disconnect

-- | Set up and run a client from the given config.
runClient :: MQTTConfig -> IO MQTTClient
runClient cfg@MQTTConfig{..} = runClientAppData (runTCPClient (clientSettings _port (BCS.pack _hostname))) cfg

-- | Set up and run a client connected via TLS.
runClientTLS :: MQTTConfig -> IO MQTTClient
runClientTLS cfg@MQTTConfig{..} = runClientAppData (runTLSClient (tlsClientConfig _port (BCS.pack _hostname))) cfg

pingPeriod :: Int
pingPeriod = 30000000 -- 30 seconds

-- | Set up and run a client from the given conduit AppData function.
runClientAppData :: ((AppData -> IO ()) -> IO ()) -> MQTTConfig -> IO MQTTClient
runClientAppData mkconn MQTTConfig{..} = do
  ch <- newTChanIO
  pid <- newTVarIO 0
  thr <- newTVarIO []
  acks <- newTVarIO mempty
  st <- newTVarIO Starting
  ct <- newTVarIO undefined

  let cli = MQTTClient{_ch=ch,
                       _cb=_msgCB,
                       _pktID=pid,
                       _ts=thr,
                       _acks=acks,
                       _st=st,
                       _ct=ct}

  t <- async $ clientThread cli
  s <- atomically (waitForLaunch cli t)

  when (s /= Connected) $ wait t

  pure cli

  where
    clientThread cli = E.finally connectAndRun markDisco
      where
        connectAndRun = mkconn $ \ad ->
          E.bracket (start cli ad) cancelAll (run ad)
        markDisco = atomically $ writeTVar (_st cli) Disconnected

    start c@MQTTClient{..} ad = do
      runConduit $ do
        let req = connectRequest{T._connID=BC.pack _connID,
                                 T._lastWill=_lwt,
                                 T._username=BC.pack <$> _username,
                                 T._password=BC.pack <$> _password,
                                 T._cleanSession=_cleanSession}
        yield (BL.toStrict $ toByteString req) .| appSink ad
        (ConnACKPkt (ConnACKFlags _ val)) <- appSource ad .| sinkParser parsePacket
        case val of
          ConnAccepted -> pure ()
          x            -> fail (show x)

      pure c

    run ad c@MQTTClient{..} = do
      o <- async processOut
      pch <- newTChanIO
      p <- async doPing
      to <- async (watchdog pch)
      link to

      atomically $ do
        modifyTVar' _ts (\l -> o:p:to:l)
        writeTVar _st Connected

      runConduit $ appSource ad
        .| conduitParser parsePacket
        .| C.mapM_ (\(_,x) -> liftIO (dispatch c pch x))

      where
        processOut = runConduit $
          C.repeatM (liftIO (atomically $ readTChan _ch))
          .| C.map (BL.toStrict . toByteString)
          .| appSink ad

        doPing = forever $ threadDelay pingPeriod >> sendPacketIO c PingPkt


        watchdog ch = do
          r <- timeout (pingPeriod * 3) w
          case r of
            Nothing -> E.throwIO Timeout
            Just _  -> watchdog ch

            where w = atomically . readTChan $ ch

    waitForLaunch MQTTClient{..} t = do
      writeTVar _ct t
      c <- readTVar _st
      if c == Starting then retry else pure c

    cancelAll MQTTClient{..} = mapM_ cancel =<< readTVarIO _ts

-- | Wait for a client to terminate its connection.
waitForClient :: MQTTClient -> IO (Either E.SomeException ())
waitForClient MQTTClient{..} = waitCatch =<< readTVarIO _ct

data MQTTException = Timeout | BadData deriving(Eq, Show)

instance E.Exception MQTTException

dispatch :: MQTTClient -> TChan Bool -> MQTTPkt -> IO ()
dispatch c@MQTTClient{..} pch pkt =
  case pkt of
    (PublishPkt p)                        -> pubMachine p
    (SubACKPkt (SubscribeResponse i _))   -> delegate DSubACK i
    (UnsubACKPkt (UnsubscribeResponse i)) -> delegate DUnsubACK i
    (PubACKPkt (PubACK i))                -> delegate DPubACK i
    (PubRECPkt (PubREC i))                -> delegate DPubREC i
    (PubRELPkt (PubREL i))                -> delegate DPubREL i
    (PubCOMPPkt (PubCOMP i))              -> delegate DPubCOMP i
    PongPkt                               -> atomically . writeTChan pch $ True
    x                                     -> print x

  where delegate dt pid = atomically $ do
          m <- readTVar _acks
          case Map.lookup (dt, pid) m of
            Nothing -> pure ()
            Just ch -> writeTChan ch pkt

        pubMachine PublishRequest{..}
          | _pubQoS == QoS2 = void $ async manageQoS2 >>= link
          | _pubQoS == QoS1 = notify >> sendPacketIO c (PubACKPkt (PubACK _pubPktID))
          | otherwise = notify

          where
            notify = case _cb of
                       Nothing -> pure ()
                       Just x  -> x c (blToText _pubTopic) _pubBody

            manageQoS2 = do
              ch <- newTChanIO
              atomically $ modifyTVar' _acks (Map.insert (DPubREL, _pubPktID) ch)
              E.finally (manageQoS2' ch) (atomically $ releasePktID c (DPubREL, _pubPktID))
                where
                  sendREC ch = do
                    sendPacketIO c (PubRECPkt (PubREC _pubPktID))
                    (PubRELPkt _) <- atomically $ readTChan ch
                    pure ()

                  manageQoS2' ch = do
                    v <- timeout 10000000 (sendREC ch)
                    case v of
                      Nothing -> killConn c Timeout
                      _ ->  notify >> sendPacketIO c (PubCOMPPkt (PubCOMP _pubPktID))

killConn :: E.Exception e => MQTTClient -> e -> IO ()
killConn MQTTClient{..} e = readTVarIO _ct >>= \t -> cancelWith t e

sendPacket :: MQTTClient -> MQTTPkt -> STM ()
sendPacket MQTTClient{..} p = do
  st <- readTVar _st
  when (st /= Connected) $ fail "not connected"
  writeTChan _ch p

sendPacketIO :: MQTTClient -> MQTTPkt -> IO ()
sendPacketIO c = atomically . sendPacket c

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

reservePktID :: MQTTClient -> [DispatchType] -> STM (TChan MQTTPkt, Word16)
reservePktID MQTTClient{..} dts = do
  ch <- newTChan
  pid <- readTVar _pktID
  modifyTVar' _pktID succ
  modifyTVar' _acks (Map.union (Map.fromList [((t, pid), ch) | t <- dts]))
  pure (ch,pid)

releasePktID :: MQTTClient -> (DispatchType,Word16) -> STM ()
releasePktID MQTTClient{..} k = modifyTVar' _acks (Map.delete k)

releasePktIDs :: MQTTClient -> [(DispatchType,Word16)] -> STM ()
releasePktIDs MQTTClient{..} ks = modifyTVar' _acks deleteMany
  where deleteMany m = foldr Map.delete m ks

sendAndWait :: MQTTClient -> DispatchType -> (Word16 -> MQTTPkt) -> IO MQTTPkt
sendAndWait c@MQTTClient{..} dt f = do
  (ch,pid) <- atomically $ do
    (ch,pid) <- reservePktID c [dt]
    sendPacket c (f pid)
    pure (ch,pid)

  -- Wait for the response in a separate transaction.
  atomically $ releasePktID c (dt,pid) >> readTChan ch

-- | Subscribe to a list of topic filters with their respective QoSes.
-- The accepted QoSes are returned in the same order as requested.
subscribe :: MQTTClient -> [(Filter, QoS)] -> IO [Maybe QoS]
subscribe c@MQTTClient{..} ls = do
  r <- sendAndWait c DSubACK (\pid -> SubscribePkt $ SubscribeRequest pid ls')
  let (SubACKPkt (SubscribeResponse _ rs)) = r
  pure rs

    where ls' = map (\(s, i) -> (textToBL s, i)) ls

-- | Unsubscribe from a list of topic filters.
unsubscribe :: MQTTClient -> [Filter] -> IO ()
unsubscribe c@MQTTClient{..} ls =
  void $ sendAndWait c DUnsubACK (\pid -> UnsubscribePkt $ UnsubscribeRequest pid (map textToBL ls))

-- | Publish a message (QoS 0).
publish :: MQTTClient
        -> Topic         -- ^ Topic
        -> BL.ByteString -- ^ Message body
        -> Bool          -- ^ Retain flag
        -> IO ()
publish c t m r = void $ publishq c t m r QoS0

-- | Publish a message with the specified QoS.
publishq :: MQTTClient
         -> Topic         -- ^ Topic
         -> BL.ByteString -- ^ Message body
         -> Bool          -- ^ Retain flag
         -> QoS           -- ^ QoS
         -> IO ()
publishq c t m r q = do
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

      pkt dup pid = (PublishPkt $ PublishRequest {
                        _pubDup = dup,
                        _pubQoS = q,
                        _pubPktID = pid,
                        _pubRetain = r,
                        _pubTopic = textToBL t,
                        _pubBody = m})

      satisfyQoS p ch pid
        | q == QoS0 = pure ()
        | q == QoS1 = void $ atomically $ readTChan ch
        | q == QoS2 = waitRec
        | otherwise = error "invalid QoS"

        where
          waitRec = do
            (PubRECPkt _) <- atomically $ readTChan ch
            sendPacketIO c (PubRELPkt $ PubREL pid)
            cancel p -- must not publish after rel
            void $ atomically $ readTChan ch

-- | Disconnect from the MQTT server.
disconnect :: MQTTClient -> IO ()
disconnect c@MQTTClient{..} = race_ getDisconnected orDieTrying
  where
    getDisconnected = sendPacketIO c DisconnectPkt >> waitForClient c
    orDieTrying = threadDelay 10000000 >> killConn c Timeout

-- | A convenience method for creating a LastWill, with a default QoS set at QoS0.
mkLWT :: Topic -> BL.ByteString -> Bool -> T.LastWill
mkLWT t m r = T.LastWill{
  T._willRetain=r,
  T._willQoS=QoS0,
  T._willTopic = textToBL t,
  T._willMsg=m
  }
