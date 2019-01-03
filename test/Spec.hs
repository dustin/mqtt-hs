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
import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck           as QC

import           Network.MQTT.Types

prop_rtLengthParser :: NonNegative (Large Int) -> Property
prop_rtLengthParser (NonNegative (Large x)) =
  x <= 268435455 ==> label (show (length e) <> "B") $
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

instance Arbitrary ConnectRequest where
  arbitrary = do
    u <- mastr
    p <- mastr
    cid <- astr
    cs <- arbitrary
    ka <- arbitrary

    pure ConnectRequest{_username=u, _password=p, _lastWill=Nothing,
                        _cleanSession=cs, _keepAlive=ka, _connID=cid}

mastr :: Gen (Maybe L.ByteString)
mastr = fmap (L.fromStrict . BC.pack . getUnicodeString) <$> arbitrary

astr :: Gen L.ByteString
astr = L.fromStrict . BC.pack . getUnicodeString <$> arbitrary

instance Arbitrary ConnACKFlags where arbitrary = ConnACKFlags <$> arbitrary <*> choose (0,5)

instance Arbitrary PublishRequest where
  arbitrary = do
    _pubDup <- arbitrary
    _pubQoS <- choose (0,2)
    _pubRetain <- arbitrary
    _pubTopic <- astr
    _pubPktID <- if _pubQoS == 0 then pure 0 else arbitrary
    _pubBody <- astr
    pure PublishRequest{..}

instance Arbitrary SubscribeRequest where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> SubscribeRequest pid <$> vectorOf n sub
    where sub = liftA2 (,) astr (choose (0,2))

instance Arbitrary SubscribeResponse where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> SubscribeResponse pid <$> vectorOf n sub
    where sub = oneof (pure <$> [0, 1, 2, 0x80])
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

instance Arbitrary MQTTPkt where
  arbitrary = oneof [
    ConnPkt <$> arbitrary,
    ConnACKPkt <$> arbitrary,
    PublishPkt <$> arbitrary,
    SubscribePkt <$> arbitrary,
    SubACKPkt <$> arbitrary,
    UnsubscribePkt <$> arbitrary,
    UnsubACKPkt <$> arbitrary,
    pure PingPkt, pure PongPkt, pure DisconnectPkt
    ]
  shrink (SubACKPkt x)      = SubACKPkt <$> shrink x
  shrink (UnsubscribePkt x) = UnsubscribePkt <$> shrink x
  shrink _                  = []

prop_PacketRT :: MQTTPkt -> Property
prop_PacketRT p = label (lab p) $ case A.parse parsePacket (toByteString p) of
                                    (A.Fail _ _ _) -> False
                                    (A.Done _ r)   -> r == p

  where lab x = let (s,_) = break (== ' ') . show $ x in s

tests :: [TestTree]
tests = [
  localOption (QC.QuickCheckTests 10000) $ testProperty "header length rt (parser)" prop_rtLengthParser,

  testCase "rt some packets" testPacketRT,
  testProperty "rt packets" prop_PacketRT
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
