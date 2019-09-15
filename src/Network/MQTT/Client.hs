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
are supported.
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client (
  -- * Configuring the client.
  MQTTConfig(..), MQTTClient, QoS(..), Topic, mqttConfig,  mkLWT, LastWill(..),
  ProtocolLevel(..), Property(..), SubOptions(..), subOptions,
  -- * Running and waiting for the client.
  runClient, runClientTLS, waitForClient,
  connectURI,
  disconnect, normalDisconnect,
  -- * General client interactions.
  subscribe, unsubscribe, publish, publishq, pubAliased,
  svrProps
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
import           Control.Monad              (forever, guard, void, when)
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
import           Data.Maybe                 (fromMaybe)
import           Data.Text                  (Text)
import qualified Data.Text.Encoding         as TE
import           Data.Word                  (Word16)
import           Network.URI                (URI (..), unEscapeString, uriPort,
                                             uriRegName, uriUserInfo)
import           System.Timeout             (timeout)



import           Network.MQTT.Topic         (Filter, Topic)
import           Network.MQTT.Types         as T

data ConnState = Starting | Connected | Disconnected | DiscoErr DisconnectRequest deriving (Eq, Show)

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
  _ch         :: TChan MQTTPkt
  , _pktID    :: TVar Word16
  , _cb       :: Maybe (MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ())
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
  _hostname       :: String -- ^ Host to connect to.
  , _port         :: Int -- ^ Port number.
  , _connID       :: String -- ^ Unique connection ID (required).
  , _username     :: Maybe String -- ^ Optional username.
  , _password     :: Maybe String -- ^ Optional password.
  , _cleanSession :: Bool -- ^ False if a session should be reused.
  , _lwt          :: Maybe LastWill -- ^ LastWill message to be sent on client disconnect.
  , _msgCB        :: Maybe (MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()) -- ^ Callback for incoming messages.
  , _protocol     :: ProtocolLevel -- ^ Protocol to use for the connection.
  , _connProps    :: [Property] -- ^ Properties to send to the broker in the CONNECT packet.
  }

-- | A default MQTTConfig.  A _connID /should/ be provided by the
-- client in the returned config, but the defaults should work for
-- testing.  In MQTTv5, an empty connection ID may be sent and the
-- server may assign an identifier for you and return it in the
-- 'PropAssignedClientIdentifier' property.
mqttConfig :: MQTTConfig
mqttConfig = MQTTConfig{_hostname="localhost", _port=1883, _connID="haskell-mqtt",
                        _username=Nothing, _password=Nothing,
                        _cleanSession=True, _lwt=Nothing,
                        _msgCB=Nothing,
                        _protocol=Protocol311, _connProps=mempty}


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

  when (s /= Connected) $ wait t

  pure cli

  where
    clientThread cli = E.finally connectAndRun markDisco
      where
        connectAndRun = mkconn $ \ad ->
          E.bracket (start cli ad) cancelAll (run ad)
        markDisco = atomically $ do
          st <- readTVar (_st cli)
          guard $ st == Connected
          writeTVar (_st cli) Disconnected

    start c@MQTTClient{..} ad = do
      runConduit $ do
        let req = connectRequest{T._connID=BC.pack _connID,
                                 T._lastWill=_lwt,
                                 T._username=BC.pack <$> _username,
                                 T._password=BC.pack <$> _password,
                                 T._cleanSession=_cleanSession,
                                 T._properties=_connProps}
        yield (BL.toStrict $ toByteString _protocol req) .| appSink ad
        (ConnACKPkt (ConnACKFlags _ val props)) <- appSource ad .| sinkParser (parsePacket _protocol)
        case val of
          ConnAccepted -> liftIO $ atomically $ writeTVar _svrProps props
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
        .| conduitParser (parsePacket _protocol)
        .| C.mapM_ (\(_,x) -> liftIO (dispatch c pch x))

      where
        processOut = runConduit $
          C.repeatM (liftIO (atomically $ checkConnected c >> readTChan _ch))
          .| C.map (BL.toStrict . toByteString _protocol)
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

data MQTTException = Timeout | BadData | Discod DisconnectRequest deriving(Eq, Show)

instance E.Exception MQTTException

dispatch :: MQTTClient -> TChan Bool -> MQTTPkt -> IO ()
dispatch c@MQTTClient{..} pch pkt =
  case pkt of
    (PublishPkt p)                            -> pubMachine p
    (SubACKPkt (SubscribeResponse i _ _))     -> delegate DSubACK i
    (UnsubACKPkt (UnsubscribeResponse i _ _)) -> delegate DUnsubACK i
    (PubACKPkt (PubACK i _ _))                -> delegate DPubACK i
    (PubRECPkt (PubREC i _ _))                -> delegate DPubREC i
    (PubRELPkt (PubREL i _ _))                -> delegate DPubREL i
    (PubCOMPPkt (PubCOMP i _ _))              -> delegate DPubCOMP i
    (DisconnectPkt req)                       -> disco req
    PongPkt                                   -> atomically . writeTChan pch $ True
    x                                         -> print x

  where delegate dt pid = atomically $ do
          m <- readTVar _acks
          case Map.lookup (dt, pid) m of
            Nothing -> pure ()
            Just ch -> writeTChan ch pkt

        disco req = do
          t <- readTVarIO _ct
          atomically $ writeTVar _st (DiscoErr req)
          cancelWith t (Discod req)

        pubMachine PublishRequest{..}
          | _pubQoS == QoS2 = void $ async manageQoS2 >>= link
          | _pubQoS == QoS1 = notify >> sendPacketIO c (PubACKPkt (PubACK _pubPktID 0 mempty))
          | otherwise = notify

          where
            notify = do
              topic <- resolveTopic (foldr aliasID Nothing _pubProps)
              case _cb of
                Nothing -> pure ()
                Just x  -> x c topic _pubBody _pubProps

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
                      _ ->  notify >> sendPacketIO c (PubCOMPPkt (PubCOMP _pubPktID 0 mempty))

killConn :: E.Exception e => MQTTClient -> e -> IO ()
killConn MQTTClient{..} e = readTVarIO _ct >>= \t -> cancelWith t e

checkConnected :: MQTTClient -> STM ()
checkConnected MQTTClient{..} = readTVar _st >>= check
  where
    check Starting       = fail "not yet connected"
    check Connected      = pure ()
    check Disconnected   = fail "disconnected"
    check (DiscoErr req) = fail (show req)

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
    when (st /= Connected) $ fail "disconnected waiting for response"
    releasePktID c (dt,pid)
    readTChan ch

-- | Subscribe to a list of topic filters with their respective QoSes.
-- The accepted QoSes are returned in the same order as requested.
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
            when (st /= 0) $ fail ("qos 1 publish error: " <> show st <> " " <> show pprops)
        | q == QoS2 = waitRec
        | otherwise = error "invalid QoS"

        where
          waitRec = do
            (PubRECPkt (PubREC _ st recprops)) <- atomically $ readTChan ch
            when (st /= 0) $ fail ("qos 2 REC publish error: " <> show st <> " " <> show recprops)
            sendPacketIO c (PubRELPkt $ PubREL pid 0 mempty)
            cancel p -- must not publish after rel
            (PubCOMPPkt (PubCOMP _ st' compprops)) <- atomically $ readTChan ch
            when (st' /= 0) $ fail ("qos 2 COMP publish error: " <> show st' <> " " <> show compprops)

-- | Disconnect from the MQTT server.
disconnect :: MQTTClient -> DiscoReason -> [Property] -> IO ()
disconnect c@MQTTClient{..} reason props = race_ getDisconnected orDieTrying
  where
    getDisconnected = sendPacketIO c (DisconnectPkt $ DisconnectRequest reason props) >> waitForClient c
    orDieTrying = threadDelay 10000000 >> killConn c Timeout

-- | Disconnect with 'DiscoNormalDisconnection' and no properties.
normalDisconnect :: MQTTClient -> IO ()
normalDisconnect c = disconnect c DiscoNormalDisconnection mempty

-- | A convenience method for creating a LastWill.
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

-- | Publish a message with the specified QoS and Properties list.  If
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
