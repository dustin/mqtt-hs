{-# LANGUAGE OverloadedStrings #-}

import           Control.Monad                   (mapM_)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString.Lazy            as L
import           Data.Word                       (Word8)
import           Network.MQTT.Arbitrary
import           Network.MQTT.Topic
import           Network.MQTT.Types              as MT
import           Test.QuickCheck                 as QC
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck           as QC

prop_rtLengthParser :: SizeT -> QC.Property
prop_rtLengthParser (SizeT x) =
  label (show (length e) <> "B") $
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

prop_PacketRT50 :: MQTTPkt -> QC.Property
prop_PacketRT50 p = label (lab p) $ case A.parse (parsePacket Protocol50) (toByteString Protocol50 p) of
                                         A.Fail{}     -> False
                                         (A.Done _ r) -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

prop_PacketRT311 :: MQTTPkt -> QC.Property
prop_PacketRT311 p = available p ==>
  let p' = v311mask p in
    label (lab p') $ case A.parse (parsePacket Protocol311) (toByteString Protocol311 p') of
                      A.Fail{}     -> False
                      (A.Done _ r) -> r == p'

  where
    lab x = let (s,_) = break (== ' ') . show $ x in s

    available (AuthPkt _) = False
    available _           = True

prop_PropertyRT :: MT.Property -> QC.Property
prop_PropertyRT p = label (lab p) $ case A.parse parseProperty (toByteString Protocol50 p) of
                                    A.Fail{}     -> False
                                    (A.Done _ r) -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

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
                        tsts = [("a", ["a"]), ("a/#", ["a/b", "a/b/c/d"]),
                                ("+/b", ["a/b"]),
                                ("+/+/c/+", ["a/b/c/d", "b/a/c/d"]),
                                ("+/+/b", []),
                                ("+/$SYS/b", ["a/$SYS/b"]),
                                ("$SYS/#", ["$SYS/a/b"]),
                                ("+/$SYS/+", ["a/$SYS/b"]),
                                ("#/b", [])] in
    map (\(p,want) -> testCase (show p) $ assertEqual "" want (filter (match p) allTopics)) tsts

prop_TopicMatching :: MatchingTopic -> QC.Property
prop_TopicMatching (MatchingTopic (t,m)) = counterexample (show m <> " doesn't match " <> show t) $ match m t

byteRT :: (ByteSize a, Show a, Eq a) => a -> Bool
byteRT x = x == (fromByte . toByte) x

tests :: [TestTree]
tests = [
  localOption (QC.QuickCheckTests 10000) $ testProperty "header length rt (parser)" prop_rtLengthParser,

  testCase "rt some packets" testPacketRT,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt packets 3.11" prop_PacketRT311,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt packets 5.0" prop_PacketRT50,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt property" prop_PropertyRT,
  testProperty "rt properties" prop_PropertiesRT,
  testProperty "sub options" prop_SubOptionsRT,

  testProperty "conn reasons" (byteRT :: ConnACKRC -> Bool),
  testProperty "disco reasons" (byteRT :: DiscoReason -> Bool),

  testGroup "topic matching" testTopicMatching,
  testProperty "arbitrary topic matching" prop_TopicMatching
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
