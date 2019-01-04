{-|
Module      : Network.MQTT.Client.
Description : An MQTT client.
Copyright   : (c) Dustin Sallings, 2019
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

An MQTT client.
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client (
  -- * Configuring the client.
  MQTTConfig(..), MQTTClient, QoS(..), mqttConfig,  mkLWT,
  -- * Running and waiting for the client.
  runClient, waitForClient,
  disconnect,
  -- * General client interactions.
  subscribe, unsubscribe, publish, publishq
  ) where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async        (Async, async, cancel,
                                                  cancelWith, race, race_, wait,
                                                  waitCatch, withAsync)
import           Control.Concurrent.STM          (STM, TChan, TVar, atomically,
                                                  modifyTVar', newTChan,
                                                  newTChanIO, newTVarIO,
                                                  readTChan, readTVar,
                                                  readTVarIO, retry, writeTChan,
                                                  writeTVar)
import qualified Control.Exception               as E
import           Control.Monad                   (forever, void, when)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as BL
import qualified Data.ByteString.Lazy.Char8      as BC
import           Data.Either                     (fromRight, isLeft)
import           Data.IntMap                     (IntMap)
import qualified Data.IntMap                     as IntMap
import           Data.Text                       (Text)
import qualified Data.Text.Encoding              as TE
import           Data.Word                       (Word16)
import           Network.Socket                  (SocketType (..), addrAddress,
                                                  addrFamily, addrProtocol,
                                                  addrSocketType, close,
                                                  connect, defaultHints,
                                                  getAddrInfo, socket)
import           Network.Socket.ByteString.Lazy  (getContents, sendAll)
import           Prelude                         hiding (getContents)

import           Network.MQTT.Types              as T

data ConnState = Starting | Connected | Disconnected deriving (Eq, Show)

-- | The MQTT client.
data MQTTClient = MQTTClient {
  _out     :: BL.ByteString -> IO ()
  , _in    :: BL.ByteString
  , _ch    :: TChan MQTTPkt
  , _pktID :: TVar Word16
  , _cb    :: Maybe (Text -> BL.ByteString -> IO ())
  , _ts    :: TVar [Async ()]
  , _acks  :: TVar (IntMap (TChan MQTTPkt))
  , _st    :: TVar ConnState
  , _ct    :: TVar (Async ())
  }

-- | Configuration for setting up an MQTT client.
data MQTTConfig = MQTTConfig{
  _hostname       :: String -- ^ Host to connect to.
  , _service      :: String -- ^ Service name or port number.
  , _connID       :: String -- ^ Unique connection ID (required).
  , _username     :: Maybe String -- ^ Optional username.
  , _password     :: Maybe String -- ^ Optional password.
  , _cleanSession :: Bool -- ^ False if a session should be reused.
  , _lwt          :: Maybe LastWill -- ^ LastWill message to be sent on client disconnect.
  , _msgCB        :: Maybe (Text -> BL.ByteString -> IO ()) -- ^ Callback for incoming messages.
  }

-- | A default MQTTConfig.  A _connID /should/ be provided by the client in the returned config,
-- but the defaults should work for testing.
mqttConfig :: MQTTConfig
mqttConfig = MQTTConfig{_hostname="localhost", _service="1883", _connID="haskell-mqtt",
                        _username=Nothing, _password=Nothing,
                        _cleanSession=True, _lwt=Nothing,
                        _msgCB=Nothing}

-- | Set up and run a client from the given config.
runClient :: MQTTConfig -> IO MQTTClient
runClient MQTTConfig{..} = do
  ch <- newTChanIO
  pid <- newTVarIO 0
  thr <- newTVarIO []
  acks <- newTVarIO mempty
  st <- newTVarIO Starting
  ct <- newTVarIO undefined

  let cli = MQTTClient{_out=undefined,
                       _in=mempty,
                       _ch=ch,
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
    clientThread cli = E.finally resolveConnRun markDisco
      where
        resolveConnRun = resolve _hostname _service >>= \addr ->
                           E.bracket (open addr) close $ \s -> E.bracket (start cli s) cancelAll dispatch
        markDisco = atomically $ writeTVar (_st cli) Disconnected

    resolve host port = do
      let hints = defaultHints { addrSocketType = Stream }
      addr:_ <- getAddrInfo (Just hints) (Just host) (Just port)
      pure addr
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      pure sock
    start c@MQTTClient{..} s = do
      _in <- getContents s
      let out = sendAll s
          r = connectRequest{T._connID=BC.pack _connID,
                             T._lastWill=_lwt,
                             T._username=BC.pack <$> _username,
                             T._password=BC.pack <$> _password,
                             T._cleanSession=_cleanSession}
      out (toByteString r)
      let (A.Done in' res) = A.parse parsePacket _in
      let (ConnACKPkt (ConnACKFlags _ val)) = res
      case val of
        0 -> pure ()
        1 -> fail "unacceptable protocol version"
        2 -> fail "identifier rejected"
        3 -> fail "server unavailable"
        4 -> fail "bad username or password"
        5 -> fail "not authorized"
        x -> fail ("unknown conn ack response: " <> show x)

      let c' = c{_out=out, _in=in'}
      w <- async $ forever $ (atomically . readTChan) _ch >>= out . toByteString
      p <- async $ forever $ sendPacketIO c' PingPkt >> threadDelay 30000000

      atomically $ do
        modifyTVar' _ts (\l -> w:p:l)
        writeTVar _st Connected

      pure c'

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

dispatch :: MQTTClient -> IO ()
dispatch c@MQTTClient{..} = do
  epkt <- race (threadDelay 60000000) (pure $! A.parse parsePacket _in)
  when (isLeft epkt) $ E.throwIO Timeout
  when (isLeft (A.eitherResult $ fromRight undefined epkt)) $ E.throwIO BadData

  let (Right (A.Done s' res)) = epkt
  case res of
    (PublishPkt PublishRequest{..}) -> case _cb of
                                         Nothing -> pure ()
                                         Just x -> x (blToText _pubTopic) _pubBody
    (SubACKPkt (SubscribeResponse i _)) -> delegate res i
    (UnsubACKPkt (UnsubscribeResponse i)) -> delegate res i
    (PubACKPkt (PubACK i)) -> delegate res i
    (PubRECPkt (PubREC i)) -> delegate res i
    (PubRELPkt (PubREL i)) -> delegate res i
    (PubCOMPPkt (PubCOMP i)) -> delegate res i
    PongPkt -> pure ()
    x -> print x
  dispatch c{_in=s'}

  where delegate pkt pid = atomically $ do
          m <- readTVar _acks
          case IntMap.lookup (fromEnum pid) m of
            Nothing -> pure ()
            Just ch -> writeTChan ch pkt

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

reservePktID :: MQTTClient -> STM (TChan MQTTPkt, Word16)
reservePktID MQTTClient{..}= do
  ch <- newTChan
  pid <- readTVar _pktID
  modifyTVar' _pktID succ
  modifyTVar' _acks (IntMap.insert (fromEnum pid) ch)
  pure (ch,pid)

releasePktID :: MQTTClient -> Word16 -> STM ()
releasePktID MQTTClient{..} p = modifyTVar' _acks (IntMap.delete (fromEnum p))

sendAndWait :: MQTTClient -> (Word16 -> MQTTPkt) -> IO (MQTTPkt)
sendAndWait c@MQTTClient{..} f = do
  (ch,pid) <- atomically $ do
    (ch,pid) <- reservePktID c
    sendPacket c (f pid)
    pure (ch,pid)

  -- Wait for the response in a separate transaction.
  atomically $ releasePktID c pid >> readTChan ch

-- | Subscribe to a list of topics with their respective QoSes.  The
-- accepted QoSes are returned in the same order.
subscribe :: MQTTClient -> [(Text, QoS)] -> IO [Maybe QoS]
subscribe c@MQTTClient{..} ls = do
  r <- sendAndWait c (\pid -> SubscribePkt $ SubscribeRequest pid ls')
  let (SubACKPkt (SubscribeResponse _ rs)) = r
  pure rs

    where ls' = map (\(s, i) -> (textToBL s, i)) ls

-- | Unsubscribe from a list of topics.
unsubscribe :: MQTTClient -> [Text] -> IO ()
unsubscribe c@MQTTClient{..} ls = do
  void $ sendAndWait c (\pid -> UnsubscribePkt $ UnsubscribeRequest pid (map textToBL ls))

-- | Publish a message (QoS 0).
publish :: MQTTClient
        -> Text          -- ^ Topic
        -> BL.ByteString -- ^ Message body
        -> Bool          -- ^ Retain flag
        -> IO ()
publish c t m r = void $ publishq c t m r QoS0

-- | Publish a message with the specified QoS.
publishq :: MQTTClient
         -> Text          -- ^ Topic
         -> BL.ByteString -- ^ Message body
         -> Bool          -- ^ Retain flag
         -> QoS           -- ^ QoS
         -> IO ()
publishq c t m r q = do
  (ch,pid) <- atomically $ reservePktID c
  E.finally (publishAndWait ch pid) (atomically $ releasePktID c pid)

    where
      publishAndWait ch pid = withAsync (pub False pid) (\p -> satisfyQoS p ch pid)

      pub dup pid = do
        sendPacketIO c (PublishPkt $ PublishRequest {
                           _pubDup = dup,
                           _pubQoS = q,
                           _pubPktID = pid,
                           _pubRetain = r,
                           _pubTopic = textToBL t,
                           _pubBody = m})
        threadDelay 5000000
        pub True pid

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
    orDieTrying = threadDelay 10000000 >> readTVarIO _ct >>= \t -> cancelWith t Timeout

-- | A convenience method for creating a LastWill.
mkLWT :: Text -> BL.ByteString -> Bool -> T.LastWill
mkLWT t m r = T.LastWill{
  T._willRetain=r,
  T._willQoS=QoS0,
  T._willTopic = textToBL t,
  T._willMsg=m
  }
