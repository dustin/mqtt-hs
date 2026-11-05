{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ClientSpec where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async        (mapConcurrently_)
import           Control.Concurrent.Async        (async, poll, wait)
import           Control.Concurrent.STM          (TVar, atomically, check, modifyTVar', newTChanIO, newTVarIO,
                                                  readTChan, readTVar, retry, writeTChan, writeTVar)
import           Control.Monad                   (forM_, forever, replicateM_)
import qualified Control.Exception               as E
import           Control.Monad.IO.Class          (liftIO)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString                 as BS
import qualified Data.ByteString.Lazy            as BL
import           Data.Conduit                    (awaitForever, yield)
import           Data.Word                       (Word16)
import           System.Timeout                  (timeout)
import           Test.Tasty.HUnit

import           Network.MQTT.Client
import           Network.MQTT.Types              as MT

-- | A fake broker for a client to connect to.  It accepts the connection
-- with the given CONNACK properties and records everything the client
-- writes after the CONNECT.  (The client writes each packet in one
-- chunk.)
fakeBroker :: [MT.Property] -> IO (TVar [BS.ByteString], (MQTTConduit -> IO ()) -> IO ())
fakeBroker props = (\(w, _, c) -> (w, c)) <$> scriptedBroker props

-- | A fake broker that also sends the client whatever packets it's given.
scriptedBroker :: [MT.Property] -> IO (TVar [BS.ByteString], MQTTPkt -> IO (), (MQTTConduit -> IO ()) -> IO ())
scriptedBroker props = do
  written <- newTVarIO []
  inject <- newTChanIO
  let enc = BL.toStrict . toByteString Protocol50
      src = yield (enc $ ConnACKPkt (ConnACKFlags NewSession ConnAccepted props))
            >> forever (liftIO (atomically (readTChan inject)) >>= yield . enc)
      sink = awaitForever $ \bs -> liftIO . atomically $ modifyTVar' written (<> [bs])
  pure (written, atomically . writeTChan inject, \f -> f (src, sink))

-- | Wait for the client to have written the nth packet after its CONNECT.
nthWritten :: Int -> TVar [BS.ByteString] -> IO MQTTPkt
nthWritten n written = do
  got <- timeout 5000000 . atomically $ do
    ws <- drop 1 <$> readTVar written
    check (length ws >= n)
    pure (ws !! (n - 1))
  bs <- maybe (assertFailure ("packet " <> show n <> " never arrived")) pure got
  either (assertFailure . ("unparseable packet: " <>)) pure . A.eitherResult . A.parse (parsePacket Protocol50) $ BL.fromStrict bs

-- | The PUBLISHes a fake broker received, in order, once there are n.
published :: Int -> TVar [BS.ByteString] -> IO [PublishRequest]
published n written = do
  got <- timeout 5000000 . atomically $ do
    ws <- drop 1 <$> readTVar written -- the CONNECT
    check (length ws >= n)
    pure ws
  ws <- maybe (assertFailure "publishes never arrived") pure got
  pure [p | Right (PublishPkt p) <- A.eitherResult . A.parse (parsePacket Protocol50) . BL.fromStrict <$> ws]

incomingPublish :: QoS -> Word16 -> MQTTPkt
incomingPublish q i = PublishPkt PublishRequest{_pubDup=False, _pubQoS=q, _pubRetain=False, _pubTopic="a/b",
                                                _pubPktID=i, _pubBody="x", _pubProps=[]}

-- Concurrent aliased publishes to one topic: the first PUBLISH using the
-- alias has to carry the topic too, or the broker can't know what the
-- alias means [5.0 §3.3.2.3.4].
unit_concurrentAliasedPublishes :: Assertion
unit_concurrentAliasedPublishes = replicateM_ 200 $ do
  (written, conn) <- fakeBroker [PropTopicAliasMaximum 10]
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  mapConcurrently_ (\_ -> pubAliased c "a/b" "x" False QoS0 []) [1 .. 200 :: Int]
  ps <- published 200 written
  forM_ (take 1 ps) $ \p ->
    assertEqual ("first publish names the topic: " <> show p) "a/b" (_pubTopic p)
  stopClient c

-- A QoS 2 publish holds its packet ID until the PUBCOMP, since until then
-- the broker still has the exchange open, and a new PUBLISH reusing the
-- ID would be taken as a duplicate and dropped [MQTT-4.3.3].
unit_qos2HoldsIDUntilPubCOMP :: Assertion
unit_qos2HoldsIDUntilPubCOMP = do
  (written, inject, conn) <- scriptedBroker []
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  p <- async $ publishq c "a/b" "x" False QoS2 []
  PublishPkt PublishRequest{_pubPktID=pid} <- nthWritten 1 written
  inject (PubRECPkt (PubREC pid 0 []))
  nthWritten 2 written >>= assertEqual "PUBREL" (PubRELPkt (PubREL pid 0 []))
  threadDelay 100000
  poll p >>= maybe (pure ()) (const $ assertFailure "publish finished before PUBCOMP")
  inject (PubCOMPPkt (PubCOMP pid 0 []))
  timeout 2000000 (wait p) >>= maybe (assertFailure "publish didn't finish after PUBCOMP") pure
  stopClient c

-- The client pings often enough for a Server Keep Alive shorter than its
-- own ping period [MQTT-3.2.2-21].
unit_honorsServerKeepAlive :: Assertion
unit_honorsServerKeepAlive = do
  (written, _, conn) <- scriptedBroker [PropServerKeepAlive 1]
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  timeout 1500000 (nthWritten 1 written) >>= \case
    Just PingPkt -> pure ()
    x            -> assertFailure ("expected a PINGREQ within 1.5s, got " <> show x)
  stopClient c

-- No more QoS 1 and 2 PUBLISHes are in flight than the server's Receive
-- Maximum [MQTT-3.3.4-7].
unit_honorsReceiveMaximum :: Assertion
unit_honorsReceiveMaximum = do
  (written, inject, conn) <- scriptedBroker [PropReceiveMaximum 1]
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50}
  ps <- mapM (\b -> async $ publishq c "a/b" b False QoS1 []) ["one", "two"]
  PublishPkt PublishRequest{_pubPktID=pid} <- nthWritten 1 written
  threadDelay 200000
  n <- length . drop 1 <$> atomically (readTVar written)
  assertEqual "PUBLISHes in flight before the first ack" 1 n
  inject (PubACKPkt (PubACK pid 0 []))
  PublishPkt PublishRequest{_pubPktID=pid2} <- nthWritten 2 written
  inject (PubACKPkt (PubACK pid2 0 []))
  mapM_ (\p -> timeout 2000000 (wait p) >>= maybe (assertFailure "publish didn't finish") pure) ps
  stopClient c

-- An ordered callback gets messages even without a subscribe on this
-- connection (e.g. from a resumed session's subscriptions).
unit_orderedCallbackWithoutSubscribe :: Assertion
unit_orderedCallbackWithoutSubscribe = do
  (_, inject, conn) <- scriptedBroker []
  got <- newTVarIO Nothing
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50,
                                      _msgCB=OrderedCallback (\_ t _ _ -> atomically $ modifyTVar' got (const (Just t)))}
  inject (PublishPkt PublishRequest{_pubDup=False, _pubQoS=QoS0, _pubRetain=False, _pubTopic="a/b",
                                    _pubPktID=0, _pubBody="x", _pubProps=[]})
  timeout 1000000 (atomically (readTVar got >>= maybe retry pure)) >>=
    assertEqual "callback called" (Just "a/b")
  stopClient c

-- | The client's connection ends (rather than wedging) within a couple of
-- seconds.
connectionEnds :: MQTTClient -> Assertion
connectionEnds c = E.try (timeout 2000000 (waitForClient c)) >>= \case
  Right Nothing                -> assertFailure "the connection is still up"
  Left (_ :: E.SomeException)  -> pure ()
  Right (Just ())              -> pure ()

-- A PUBLISH whose topic has wildcards is a protocol error [MQTT-3.3.2-2]
-- that ends the connection, rather than wedging it.
unit_wildcardPublishEndsConnection :: Assertion
unit_wildcardPublishEndsConnection = do
  (_, inject, conn) <- scriptedBroker []
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50,
                                      _msgCB=OrderedLowLevelCallback (\_ p -> _pubTopic p `seq` pure ())}
  inject (PublishPkt PublishRequest{_pubDup=False, _pubQoS=QoS1, _pubRetain=False, _pubTopic="a/+",
                                    _pubPktID=1, _pubBody="x", _pubProps=[]})
  connectionEnds c

-- An ordered callback that fails ends the connection, as an unordered one
-- does, instead of leaving it up with nothing to handle messages.
unit_failingOrderedCallbackEndsConnection :: Assertion
unit_failingOrderedCallbackEndsConnection = do
  (_, inject, conn) <- scriptedBroker []
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50,
                                      _msgCB=OrderedCallback (\_ _ _ _ -> E.throwIO (userError "callback failed"))}
  inject (PublishPkt PublishRequest{_pubDup=False, _pubQoS=QoS1, _pubRetain=False, _pubTopic="a/b",
                                    _pubPktID=1, _pubBody="x", _pubProps=[]})
  connectionEnds c

-- An ordered client that never subscribed (e.g. a bridge's destination,
-- getting a resumed session's messages) handles, and acks, more than one
-- message: the second used to block the reader for good.
unit_orderedWithoutSubscribeAcksAll :: Assertion
unit_orderedWithoutSubscribeAcksAll = do
  (written, inject, conn) <- scriptedBroker []
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50, _msgCB=OrderedCallback (\_ _ _ _ -> pure ())}
  mapM_ (\i -> inject (PublishPkt PublishRequest{_pubDup=False, _pubQoS=QoS1, _pubRetain=False, _pubTopic="a/b",
                                                 _pubPktID=i, _pubBody="x", _pubProps=[]})) [1, 2, 3]
  acks <- mapM (`nthWritten` written) [1, 2, 3]
  assertEqual "PUBACKs" [PubACKPkt (PubACK i 0 []) | i <- [1, 2, 3]] acks
  stopClient c

-- A blocked ordered callback must not stop the reader from processing later
-- packets.  Three PUBLISHes used to fill the one-slot MVar and block the third.
unit_orderedCallbackDoesNotBlockReader :: Assertion
unit_orderedCallbackDoesNotBlockReader = do
  (_, inject, conn) <- scriptedBroker []
  started <- newTVarIO False
  release <- newTVarIO False
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50,
                                      _msgCB=OrderedCallback (\_ _ _ _ -> do
                                        atomically $ writeTVar started True
                                        atomically $ check =<< readTVar release)}
  flip E.finally (stopClient c) $ do
    mapM_ (inject . incomingPublish QoS1) [1, 2, 3]
    timeout 1000000 (atomically $ readTVar started >>= check) >>=
      maybe (assertFailure "the first callback never started") pure
    inject (DisconnectPkt (DisconnectRequest DiscoNormalDisconnection []))
    connectionEnds c

-- Ordered QoS 1 callbacks acknowledge in receive order, but only after their
-- callbacks have completed.
unit_orderedCallbacksAckAfterCompletionInOrder :: Assertion
unit_orderedCallbacksAckAfterCompletionInOrder = do
  (written, inject, conn) <- scriptedBroker []
  started <- newTVarIO []
  completed <- newTVarIO []
  release <- newTVarIO False
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50,
                                      _msgCB=OrderedLowLevelCallback (\_ p -> do
                                        atomically $ modifyTVar' started (<> [_pubPktID p])
                                        atomically $ check =<< readTVar release
                                        atomically $ modifyTVar' completed (<> [_pubPktID p]))}
  flip E.finally (stopClient c) $ do
    mapM_ (inject . incomingPublish QoS1) [1, 2, 3]
    timeout 1000000 (atomically $ readTVar started >>= check . (== [1])) >>=
      maybe (assertFailure "the first callback never started") pure
    beforeRelease <- atomically $ drop 1 <$> readTVar written
    assertEqual "PUBACKs before the callback completes" [] beforeRelease
    atomically $ writeTVar release True
    acks <- mapM (`nthWritten` written) [1, 2, 3]
    assertEqual "PUBACKs" [PubACKPkt (PubACK i 0 []) | i <- [1, 2, 3]] acks
    atomically (readTVar completed) >>= assertEqual "callback completion order" [1, 2, 3]

-- QoS 2 still sends PUBREC immediately, while PUBCOMP waits for the callback.
unit_orderedQoS2CompletesAfterCallback :: Assertion
unit_orderedQoS2CompletesAfterCallback = do
  (written, inject, conn) <- scriptedBroker []
  started <- newTVarIO False
  release <- newTVarIO False
  c <- runMQTTConduit conn mqttConfig{_protocol=Protocol50,
                                      _msgCB=OrderedCallback (\_ _ _ _ -> do
                                        atomically $ writeTVar started True
                                        atomically $ check =<< readTVar release)}
  flip E.finally (stopClient c) $ do
    inject (incomingPublish QoS2 1)
    nthWritten 1 written >>= assertEqual "PUBREC" (PubRECPkt (PubREC 1 0 []))
    inject (PubRELPkt (PubREL 1 0 []))
    timeout 1000000 (atomically $ readTVar started >>= check) >>=
      maybe (assertFailure "the callback never started") pure
    beforeRelease <- atomically $ drop 2 <$> readTVar written
    assertEqual "PUBCOMP before the callback completes" [] beforeRelease
    atomically $ writeTVar release True
    nthWritten 2 written >>= assertEqual "PUBCOMP" (PubCOMPPkt (PubCOMP 1 0 []))
