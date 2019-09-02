{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

import           Control.Applicative             (liftA2)
import           Control.Monad                   (mapM_)
import qualified Data.Attoparsec.ByteString.Lazy as A
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Char8           as BC
import qualified Data.ByteString.Lazy            as L
import           Data.Word                       (Word8)
import           Numeric                         (showHex)
import           Test.QuickCheck                 as QC
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck           as QC

import           Network.MQTT.Topic
import           Network.MQTT.Types              as MT

newtype SizeT = SizeT Int deriving(Eq, Show)

instance Arbitrary SizeT where
  arbitrary = SizeT <$> choose (0, 268435455)

prop_rtLengthParser :: SizeT -> QC.Property
prop_rtLengthParser (SizeT x) =
  label (show (length e) <> "B") $
  cover 20 (length e > 1) "multi-byte" $
  d e == x

  where e = encodeLength x
        d :: [Word8] -> Int
        d l = case A.parse parseHdrLen (L.pack l) of
                (A.Fail _ _ _) -> undefined
                (A.Done _ v)   -> v

testPacketRT :: Assertion
testPacketRT = mapM_ tryParse [
  "\DLE0\NUL\EOTMQTT\EOT\198\SOH,\NUL\ACKsomeid\NUL\btmp/test\NUL\STXhi\NUL\ACKdustin\NUL\ACKpasswd",
  " \STX\SOH\NUL"
  ]

  where
    tryParse s = do
      let (A.Done _ x) = A.parse parsePacket s
      case A.parse parsePacket (toByteString x) of
        f@(A.Fail _ _ _) -> assertFailure (show f)
        (A.Done _ x')    -> assertEqual (show s) x x'

instance Arbitrary LastWill where
  arbitrary = LastWill <$> arbitrary <*> arbitrary <*> astr <*> astr

instance Arbitrary ConnectRequest where
  arbitrary = do
    u <- mastr
    p <- mastr
    cid <- astr
    cs <- arbitrary
    ka <- arbitrary
    lw <- arbitrary

    pure ConnectRequest{_username=u, _password=p, _lastWill=lw,
                        _cleanSession=cs, _keepAlive=ka, _connID=cid,
                        _connLvl=Protocol311}

mastr :: Gen (Maybe L.ByteString)
mastr = fmap (L.fromStrict . BC.pack . getUnicodeString) <$> arbitrary

astr :: Gen L.ByteString
astr = L.fromStrict . BC.pack . getUnicodeString <$> arbitrary

instance Arbitrary QoS where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary ConnACKFlags where arbitrary = ConnACKFlags <$> arbitrary <*> (connACKRC <$> choose (0,5))

instance Arbitrary PublishRequest where
  arbitrary = do
    _pubDup <- arbitrary
    _pubQoS <- arbitrary
    _pubRetain <- arbitrary
    _pubTopic <- astr
    _pubPktID <- if _pubQoS == QoS0 then pure 0 else arbitrary
    _pubBody <- astr
    pure PublishRequest{..}

instance Arbitrary PubACK where
  arbitrary = PubACK <$> arbitrary

instance Arbitrary PubREL where
  arbitrary = PubREL <$> arbitrary

instance Arbitrary PubREC where
  arbitrary = PubREC <$> arbitrary

instance Arbitrary PubCOMP where
  arbitrary = PubCOMP <$> arbitrary

instance Arbitrary SubscribeRequest where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> SubscribeRequest pid <$> vectorOf n sub
    where sub = liftA2 (,) astr arbitrary

instance Arbitrary SubscribeResponse where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> SubscribeResponse pid <$> vectorOf n sub
    where sub = oneof (pure <$> [Just QoS0, Just QoS1, Just QoS2, Nothing])
  shrink (SubscribeResponse pid l)
    | length l == 1 = []
    | otherwise = [SubscribeResponse pid sl | sl <- shrinkList (:[]) l, length sl > 0]

instance Arbitrary UnsubscribeRequest where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> UnsubscribeRequest pid <$> vectorOf n astr
  shrink (UnsubscribeRequest p l)
    | length l == 1 = []
    | otherwise = [UnsubscribeRequest p sl | sl <- shrinkList (:[]) l, length sl > 0]

instance Arbitrary UnsubscribeResponse where
  arbitrary = UnsubscribeResponse <$> arbitrary

instance Arbitrary MT.Property where
  arbitrary = oneof [
    PropPayloadFormatIndicator <$> arbitrary,
    PropMessageExpiryInterval <$> arbitrary,
    PropMessageExpiryInterval <$> arbitrary,
    PropContentType <$> astr,
    PropResponseTopic <$> astr,
    PropCorrelationData <$> astr,
    PropSubscriptionIdentifier <$> arbitrary `suchThat` (>= 0),
    PropSessionExpiryInterval <$> arbitrary,
    PropAssignedClientIdentifier <$> astr,
    PropServerKeepAlive <$> arbitrary,
    PropAuthenticationMethod <$> astr,
    PropAuthenticationData <$> astr,
    PropRequestProblemInformation <$> arbitrary,
    PropWillDelayInterval <$> arbitrary,
    PropRequestResponseInformation <$> arbitrary,
    PropResponseInformation <$> astr,
    PropServerReference <$> astr,
    PropReasonString <$> astr,
    PropReceiveMaximum <$> arbitrary,
    PropTopicAliasMaximum <$> arbitrary,
    PropTopicAlias <$> arbitrary,
    PropMaximumQoS <$> arbitrary,
    PropRetainAvailable <$> arbitrary,
    PropUserProperty <$> astr <*> astr,
    PropMaximumPacketSize <$> arbitrary,
    PropWildcardSubscriptionAvailable <$> arbitrary,
    PropSubscriptionIdentifierAvailable <$> arbitrary,
    PropSharedSubscriptionAvailable <$> arbitrary
    ]

instance Arbitrary MQTTPkt where
  arbitrary = oneof [
    ConnPkt <$> arbitrary,
    ConnACKPkt <$> arbitrary,
    PublishPkt <$> arbitrary,
    PubACKPkt <$> arbitrary,
    PubRELPkt <$> arbitrary,
    PubRECPkt <$> arbitrary,
    PubCOMPPkt <$> arbitrary,
    SubscribePkt <$> arbitrary,
    SubACKPkt <$> arbitrary,
    UnsubscribePkt <$> arbitrary,
    UnsubACKPkt <$> arbitrary,
    pure PingPkt, pure PongPkt, pure DisconnectPkt
    ]
  shrink (SubACKPkt x)      = SubACKPkt <$> shrink x
  shrink (UnsubscribePkt x) = UnsubscribePkt <$> shrink x
  shrink _                  = []

prop_PacketRT :: MQTTPkt -> QC.Property
prop_PacketRT p = label (lab p) $ case A.parse parsePacket (toByteString p) of
                                    (A.Fail _ _ _) -> False
                                    (A.Done _ r)   -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

prop_OptionRT :: MT.Property -> QC.Property
prop_OptionRT p = label (lab p) $ case A.parse parseProperty (toByteString p) of
                                    (A.Fail _ _ _) -> False
                                    (A.Done _ r)   -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

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

tests :: [TestTree]
tests = [
  localOption (QC.QuickCheckTests 10000) $ testProperty "header length rt (parser)" prop_rtLengthParser,

  testCase "rt some packets" testPacketRT,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt packets" prop_PacketRT,
  localOption (QC.QuickCheckTests 1000) $ testProperty "rt options" prop_OptionRT,

  testGroup "topic matching" testTopicMatching
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
