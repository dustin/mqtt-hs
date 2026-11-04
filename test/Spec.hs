{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}


module Spec where

import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as L
import           Data.Foldable                   (toList, traverse_)
import           Data.String                     (fromString)
import qualified Data.Text                       as T
import           Data.Word                       (Word8)
import           Network.MQTT.Arbitrary
import           Network.MQTT.Topic
import           Network.MQTT.Types              as MT

import           Test.QuickCheck                 as QC
import           Test.QuickCheck.Checkers
import           Test.QuickCheck.Classes
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck           as QC

prop_rtLengthParser :: SizeT -> QC.Property
prop_rtLengthParser (SizeT x) =
  coverTable "Sizes" [("1B", 10), ("2B", 10), ("3B", 10), ("4B", 10)] $
  tabulate "Sizes" [show (length e) <> "B"] $
  checkCoverage $
  d e == x

  where e = encodeLength x
        d :: [Word8] -> Int
        d l = case A.parse parseHdrLen (L.pack l) of
                A.Fail{}     -> undefined
                (A.Done _ v) -> v

testPacketRT :: Assertion
testPacketRT = mapM_ tryParse [
  "\DLE0\NUL\EOTMQTT\EOT\198\SOH,\NUL\ACKsomeid\NUL\btmp/test\NUL\STXhi\NUL\ACKdustin\NUL\ACKpasswd",
  " \STX\SOH\NUL"
  ]

  where
    tryParse s = do
      let (A.Done _ x) = A.parse (parsePacket Protocol311) s
      case A.parse (parsePacket Protocol311) (toByteString Protocol311 x) of
        f@A.Fail{}    -> assertFailure (show f)
        (A.Done _ x') -> assertEqual (show s) x x'

allPktTypes :: [String]
allPktTypes = [
    "ConnPkt",
    "ConnACKPkt",
    "PublishPkt",
    "PubACKPkt",
    "PubRECPkt",
    "PubRELPkt",
    "PubCOMPPkt",
    "SubscribePkt",
    "SubACKPkt",
    "UnsubscribePkt",
    "UnsubACKPkt",
    "PingPkt",
    "PongPkt",
    "DisconnectPkt",
    "AuthPkt"
  ]

prop_PacketRT50 :: MQTTPkt -> QC.Property
prop_PacketRT50 p =
  coverTable "pkt types" ((,1) <$> allPktTypes) $
  tabulate "pkt types" [lab p] $
  checkCoverage $
  case A.parse (parsePacket Protocol50) (toByteString Protocol50 p) of
    A.Fail{}     -> False
    (A.Done _ r) -> r == p

  where lab = takeWhile (/= ' ') . show

prop_PacketRT311 :: MQTTPkt -> QC.Property
prop_PacketRT311 p = available p ==>
  label (lab p) $
  case A.parse (parsePacket Protocol311) (toByteString Protocol311 p') of
                    A.Fail{}     -> False
                    (A.Done _ r) -> r == p'

  where
    lab = takeWhile (/= ' ') . show
    p' = v311mask p

    available (AuthPkt _) = False
    available _           = True

prop_PropertyRT :: MT.Property -> QC.Property
prop_PropertyRT p = label (lab p) $ case A.parse parseProperty (toByteString Protocol50 p) of
                                    A.Fail{}     -> False
                                    (A.Done _ r) -> r == p

  where lab = takeWhile (/= ' ') . show

prop_SubOptionsRT :: SubOptions -> Bool
prop_SubOptionsRT o = case A.parse parseSubOptions (toByteString Protocol50 o) of
                      A.Fail{}     -> False
                      (A.Done _ r) -> r == o

prop_PropertiesRT :: [MT.Property] -> Bool
prop_PropertiesRT p = case A.parse (parseProperties Protocol50) (bsProps Protocol50 p) of
                        A.Fail{}     -> False
                        (A.Done _ r) -> r == p

testTopicMatching :: [TestTree]
testTopicMatching = let allTopics = ["a", "a/b", "a/b/c/d", "b/a/c/d",
                                     "$SYS/a/b", "a/$SYS/b"]
                        -- Wildcards don't match a $ level only at the start of
                        -- the topic [MQTT-4.7.2-1].
                        tsts = [("a", ["a"]), ("a/#", ["a", "a/b", "a/b/c/d", "a/$SYS/b"]),
                                ("+/b", ["a/b"]),
                                ("+/+/c/+", ["a/b/c/d", "b/a/c/d"]),
                                ("+/+/b", ["a/$SYS/b"]),
                                ("#", ["a", "a/b", "a/b/c/d", "b/a/c/d", "a/$SYS/b"]),
                                ("+/#", ["a", "a/b", "a/b/c/d", "b/a/c/d", "a/$SYS/b"]),
                                ("+/a/b", []),
                                ("+/$SYS/b", ["a/$SYS/b"]),
                                ("$SYS/#", ["$SYS/a/b"]),
                                ("+/$SYS/+", ["a/$SYS/b"]),
                                ("#/b", [])] in
    map (\(p,want) -> testCase (show p) $ assertEqual "" want (filter (match p) allTopics)) tsts

-- Wildcards must occupy a whole level, # only the last
-- [MQTT-4.7.1-1], [MQTT-4.7.1-2], [MQTT-4.7.1-3], and a topic name has
-- none [MQTT-4.7.0-1].
testFilterValidation :: Assertion
testFilterValidation = do
  mapM_ (\f -> assertEqual (show f) (Just f) (unFilter <$> mkFilter f))
    ["a", "#", "+", "a/#", "a/+/b", "+/+", "/", "a//b", "$SYS/#", "+/#"]
  mapM_ (\f -> assertEqual (show f) Nothing (unFilter <$> mkFilter f))
    ["", "a+", "a/b+/c", "a#", "a/#b", "#/a", "a/#/b", "+a"]

testTopicValidation :: Assertion
testTopicValidation = do
  mapM_ (\t -> assertEqual (show t) (Just t) (unTopic <$> mkTopic t)) ["a", "a/b", "/", "a//b", "$SYS/x"]
  mapM_ (\t -> assertEqual (show t) Nothing (unTopic <$> mkTopic t)) ["", "#", "+", "a/+", "a/#", "a+b", "a#", "a/b+"]

prop_TopicMatching :: MatchingTopic -> QC.Property
prop_TopicMatching (MatchingTopic (t,ms)) = counterexample (show ms <> " doesn't match " <> show t) $
  all (`match` t) ms

byteRT :: (ByteSize a, Show a, Eq a) => a -> Bool
byteRT x = x == (fromByte . toByte) x

testQoSFromInt :: Assertion
testQoSFromInt = do
  mapM_ (\q -> assertEqual (show q) (Just q) (qosFromInt (fromEnum q))) [QoS0 ..]
  assertEqual "invalid QoS" Nothing (qosFromInt 1939)

instance EqProp Filter where (=-=) = eq
instance EqProp Topic where (=-=) = eq

test_Spec :: [TestTree]
test_Spec = [
  testCase "rt some packets" testPacketRT,
  testCase "qosFromInt" testQoSFromInt,

  testProperty "conn reasons" (byteRT :: ConnACKRC -> Bool),
  testProperty "disco reasons" (byteRT :: DiscoReason -> Bool),

  testProperties "topic semigroup" (unbatch $ semigroup (undefined :: Topic, undefined :: Int)),
  testProperties "filter semigroup" (unbatch $ semigroup (undefined :: Filter, undefined :: Int)),

  testGroup "topic matching" testTopicMatching,
  testCase "filter validation" testFilterValidation,
  testCase "topic validation" testTopicValidation,
  testProperty "arbitrary topic matching" prop_TopicMatching
  ]

-- | Parse exactly the given bytes as a single MQTT 5 packet.
parses50 :: [Word8] -> MQTTPkt -> Assertion
parses50 bs want = case A.parse (parsePacket Protocol50) (L.pack bs) of
  A.Done "" got -> assertEqual (show bs) want got
  x             -> assertFailure (show bs <> ": " <> show x)

-- A DISCONNECT with a Remaining Length of 0 has an implied reason code
-- of 0x00 (Normal disconnection) and no properties [MQTT 5 §3.14.2.1].
unit_disconnectShort50 :: Assertion
unit_disconnectShort50 = parses50 [0xe0, 0x00] (DisconnectPkt (DisconnectRequest DiscoNormalDisconnection []))

-- A Remaining Length of 1 is a reason code with no properties [MQTT 5 §3.14.2.2.1].
unit_disconnectReasonOnly50 :: Assertion
unit_disconnectReasonOnly50 = parses50 [0xe0, 0x01, 0x04] (DisconnectPkt (DisconnectRequest DiscoDisconnectWithWill []))

-- An AUTH with a Remaining Length of 0 has an implied reason code of
-- 0x00 (Success) and no properties [MQTT 5 §3.15.2.1].
unit_authShort50 :: Assertion
unit_authShort50 = parses50 [0xf0, 0x00] (AuthPkt (AuthRequest 0x00 []))

-- A Remaining Length of 1 is a reason code with no properties [MQTT 5 §3.15.2.2.1].
unit_authReasonOnly50 :: Assertion
unit_authReasonOnly50 = parses50 [0xf0, 0x01, 0x18] (AuthPkt (AuthRequest 0x18 []))

-- | The given bytes aren't a valid packet at the given level.
rejects :: A.Parser MQTTPkt -> [Word8] -> Assertion
rejects p bs = case A.parse p (L.pack bs) of
  A.Fail{}    -> pure ()
  A.Done _ pk -> assertFailure (show bs <> " parsed as " <> show pk)

subscribeWith :: ProtocolLevel -> Word8 -> [Word8]
subscribeWith Protocol50 o  = [0x82, 0x07, 0x00, 0x01, 0x00, 0x00, 0x01, 0x61, o]
subscribeWith Protocol311 o = [0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, o]

-- Retain Handling 3 is a protocol error, and the reserved bits must be 0
-- [MQTT-3.8.3-5].  So must a QoS of 3 [MQTT-3-8.3-4].
unit_subOptionsRetainHandling3 :: Assertion
unit_subOptionsRetainHandling3 = rejects (parsePacket Protocol50) (subscribeWith Protocol50 0x30)

unit_subOptionsReserved :: Assertion
unit_subOptionsReserved = mapM_ (rejects (parsePacket Protocol50) . subscribeWith Protocol50) [0x40, 0x80]

unit_subOptionsQoS3 :: Assertion
unit_subOptionsQoS3 = rejects (parsePacket Protocol50) (subscribeWith Protocol50 0x03)

unit_subOptionsValid :: Assertion
unit_subOptionsValid = parses50 (subscribeWith Protocol50 0x2e)
  (SubscribePkt (SubscribeRequest 1 [("a", SubOptions{_retainHandling=DoNotSendOnSubscribe, _retainAsPublished=True,
                                                     _noLocal=True, _subQoS=QoS2})] []))

-- In 3.1.1, everything but the QoS is reserved [MQTT-3-8.3-4].
unit_subOptionsReserved311 :: Assertion
unit_subOptionsReserved311 = mapM_ (rejects (parsePacket Protocol311) . subscribeWith Protocol311) [0x04, 0x08, 0x10]

-- A PUBLISH can't have QoS 3 [MQTT-3.3.1-4].
unit_publishQoS3 :: Assertion
unit_publishQoS3 = rejects (parsePacket Protocol311) [0x36, 0x05, 0x00, 0x01, 0x61, 0x00, 0x01]

connectWithFlags :: Word8 -> [Word8] -> [Word8]
connectWithFlags flags rest = [0x10, fromIntegral (13 + length rest), 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, flags,
                               0x00, 0x3c, 0x00, 0x01, 0x78] <> rest

-- The CONNECT flags' reserved bit must be 0 [MQTT-3.1.2-3].
unit_connectReservedFlag :: Assertion
unit_connectReservedFlag = rejects parseConnect (connectWithFlags 0x03 [])

-- Without a will, the will QoS and retain must be 0 [MQTT-3.1.2-11],
-- [MQTT-3.1.2-13], [MQTT-3.1.2-15]; with one, its QoS isn't 3 [MQTT-3.1.2-14].
unit_connectWillFlags :: Assertion
unit_connectWillFlags = do
  mapM_ (rejects parseConnect . (`connectWithFlags` [])) [0x0a, 0x12, 0x22]
  rejects parseConnect (connectWithFlags 0x1e [0x00, 0x01, 0x74, 0x00, 0x01, 0x6d])

unit_connectValid :: Assertion
unit_connectValid = case A.parse parseConnect (L.pack (connectWithFlags 0x2e [0x00, 0x01, 0x74, 0x00, 0x01, 0x6d])) of
  A.Done "" (ConnPkt ConnectRequest{_lastWill=Just LastWill{_willQoS=QoS1, _willRetain=True}} Protocol311) -> pure ()
  x -> assertFailure (show x)

-- A CONNECT is parsed within its Remaining Length.  The will fields
-- aren't read from whatever follows it [MQTT-3.1.2-9]...
unit_connectWillFieldsMissing :: Assertion
unit_connectWillFieldsMissing = rejects parseConnect (connectWithFlags 0x06 [] <> [0x00, 0x01, 0x74, 0x00, 0x01, 0x6d])

-- ...and bytes left over after its fields make it malformed.
unit_connectTrailingBytes :: Assertion
unit_connectTrailingBytes = rejects parseConnect (connectWithFlags 0x02 [0x00])

-- In 3.1.1, a SUBSCRIBE's options byte is just the QoS; the rest is
-- reserved [MQTT-3.8.3-4], so 5.0-only options aren't encoded.
prop_subscribe311OnlyQoS :: SubOptions -> QC.Property
prop_subscribe311OnlyQoS o =
  let pkt = SubscribePkt (SubscribeRequest 1 [("a", o)] [])
  in case A.parse (parsePacket Protocol311) (toByteString Protocol311 pkt) of
       A.Done "" got -> got === SubscribePkt (SubscribeRequest 1 [("a", subOptions{_subQoS=_subQoS o})] [])
       x             -> counterexample (show x) False
