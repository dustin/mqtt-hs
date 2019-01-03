{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Client (
  MQTTConfig(..), MQTTClient,
  mqttConfig,  mkLWT, runClient, waitForClient,
  subscribe, unsubscribe, publish,
  disconnect
  ) where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async        (Async, async, cancel,
                                                  cancelWith, race, race_,
                                                  waitCatch)
import           Control.Concurrent.STM          (TChan, TVar, atomically,
                                                  modifyTVar', newTChanIO,
                                                  newTVarIO, readTChan,
                                                  readTVar, readTVarIO, retry,
                                                  writeTChan, writeTVar)
import qualified Control.Exception               as E
import           Control.Monad                   (forever, when)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as BL
import qualified Data.ByteString.Lazy.Char8      as BC
import           Data.Either                     (isLeft)
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

data MQTTClient = MQTTClient {
  _out     :: BL.ByteString -> IO ()
  , _in    :: BL.ByteString
  , _ch    :: TChan MQTTPkt
  , _pktID :: TVar Word16
  , _cb    :: Maybe (Text -> BL.ByteString -> IO ())
  , _ts    :: TVar [Async ()]
  , _acks  :: TVar (IntMap MQTTPkt)
  , _st    :: TVar ConnState
  , _ct    :: TVar (Async ())
  }

data MQTTConfig = MQTTConfig{
  _hostname       :: String
  , _service      :: String
  , _connID       :: String
  , _username     :: Maybe String
  , _password     :: Maybe String
  , _cleanSession :: Bool
  , _lwt          :: Maybe LastWill
  , _msgCB        :: Maybe (Text -> BL.ByteString -> IO ())
  }

mqttConfig :: MQTTConfig
mqttConfig = MQTTConfig{_hostname="", _service="", _connID="",
                        _username=Nothing, _password=Nothing,
                        _cleanSession=True, _lwt=Nothing,
                        _msgCB=Nothing}

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

  when (s /= Connected) $ waitCatch t >>= \c -> case c of
                               Left e  -> E.throwIO e
                               Right _ -> E.throwIO (E.AssertionFailed "unknown error establishing connection")

  pure cli

  where
    clientThread cli = E.finally resolveConnRun markDisco
      where
        resolveConnRun = resolve _hostname _service >>= \addr ->
                           E.bracket (open addr) close $ \s -> E.bracket (start cli s) cancelAll capture
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
      p <- async $ forever $ sendPacket c' PingPkt >> threadDelay 30000000

      atomically $ do
        modifyTVar' _ts (\l -> w:p:l)
        writeTVar _st Connected

      pure c'

    waitForLaunch MQTTClient{..} t = do
      writeTVar _ct t
      c <- readTVar _st
      if c == Starting then retry else pure c

    cancelAll MQTTClient{..} = mapM_ cancel =<< readTVarIO _ts

waitForClient :: MQTTClient -> IO (Either E.SomeException ())
waitForClient MQTTClient{..} = waitCatch =<< readTVarIO _ct

data MQTTException = Timeout deriving(Eq, Show)

instance E.Exception MQTTException

capture :: MQTTClient -> IO ()
capture c@MQTTClient{..} = do
  epkt <- race (threadDelay 60000000) (pure $! A.parse parsePacket _in)
  when (isLeft epkt) $ E.throwIO Timeout

  let (Right (A.Done s' res)) = epkt
  case res of
    (PublishPkt PublishRequest{..}) -> case _cb of
                                         Nothing -> pure ()
                                         Just x -> x (blToText _pubTopic) _pubBody
    (SubACKPkt (SubscribeResponse i _)) -> remember res i
    (UnsubACKPkt (UnsubscribeResponse i)) -> remember res i
    PongPkt -> pure ()
    x -> print x
  capture c{_in=s'}

  where remember pkt pid = atomically $ modifyTVar' _acks (IntMap.insert (fromEnum pid) pkt)

sendPacket :: MQTTClient -> MQTTPkt -> IO ()
sendPacket MQTTClient{..} = atomically . writeTChan _ch

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

subscribe :: MQTTClient -> [(Text, Int)] -> IO [Int]
subscribe MQTTClient{..} ls = do
  p <- atomically $ do
    pid <- readTVar _pktID
    modifyTVar' _pktID succ
    writeTChan _ch (SubscribePkt $ SubscribeRequest pid ls')
    pure pid

  let pint = fromEnum p
  r <- atomically $ do
    m <- readTVar _acks
    case IntMap.lookup pint m of
      Nothing  -> retry
      Just pkt -> modifyTVar' _acks (IntMap.delete pint) >> pure pkt

  let (SubACKPkt (SubscribeResponse _ rs)) = r
  pure $ map fromEnum rs

    where ls' = map (\(s, i) -> (textToBL s, toEnum i)) ls

unsubscribe :: MQTTClient -> [Text] -> IO ()
unsubscribe MQTTClient{..} ls = do
  p <- atomically $ do
    pid <- readTVar _pktID
    modifyTVar' _pktID succ
    writeTChan _ch (UnsubscribePkt $ UnsubscribeRequest pid ls')
    pure pid

  let pint = fromEnum p
  atomically $ do
    m <- readTVar _acks
    case IntMap.lookup pint m of
      Nothing -> retry
      Just _  -> modifyTVar' _acks (IntMap.delete pint)

  pure ()

    where ls' = map textToBL ls

publish :: MQTTClient -> Text -> BL.ByteString -> Bool -> IO ()
publish c t m r = sendPacket c (PublishPkt $ PublishRequest {
                                   _pubDup = False,
                                   _pubQoS = 0,
                                   _pubPktID = 0,
                                   _pubRetain = r,
                                   _pubTopic = textToBL t,
                                   _pubBody = m})

disconnect :: MQTTClient -> IO ()
disconnect c@MQTTClient{..} = race_ getDisconnected orDieTrying
  where
    getDisconnected = sendPacket c DisconnectPkt >> waitForClient c
    orDieTrying = threadDelay 10000000 >> readTVarIO _ct >>= \t -> cancelWith t Timeout

mkLWT :: Text -> BL.ByteString -> Bool -> T.LastWill
mkLWT t m r = T.LastWill{
  T._willRetain=r,
  T._willQoS=0,
  T._willTopic = textToBL t,
  T._willMsg=m
  }
