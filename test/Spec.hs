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
                        tsts = [("a", ["a"]), ("a/#", ["a", "a/b", "a/b/c/d"]),
                                ("+/b", ["a/b"]),
                                ("+/+/c/+", ["a/b/c/d", "b/a/c/d"]),
                                ("+/+/b", []),
                                ("+/$SYS/b", ["a/$SYS/b"]),
                                ("$SYS/#", ["$SYS/a/b"]),
                                ("+/$SYS/+", ["a/$SYS/b"]),
                                ("#/b", [])] in
    map (\(p,want) -> testCase (show p) $ assertEqual "" want (filter (match p) allTopics)) tsts

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
  testProperty "arbitrary topic matching" prop_TopicMatching
  ]
