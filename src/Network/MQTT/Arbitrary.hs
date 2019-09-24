{-|
Module       : Network.MQTT.Arbitrary
Description  : Arbitrary instances for QuickCheck.
Copyright    : (c) Dustin Sallings, 2019
License      : BSD3
Maintainer   : dustin@spy.net
Stability    : experimental

Arbitrary instances for QuickCheck.
-}

{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Network.MQTT.Arbitrary (
  SizeT(..),
  v311mask
  ) where

import           Control.Applicative   (liftA2)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy  as L
import           Network.MQTT.Types    as MT
import           Test.QuickCheck       as QC



-- | Arbitrary type fitting variable integers.
newtype SizeT = SizeT Int deriving(Eq, Show)

instance Arbitrary SizeT where
  arbitrary = SizeT <$> oneof [ choose (0, 127),
                                choose (128, 16383),
                                choose (16384, 2097151),
                                choose (2097152, 268435455)]

instance Arbitrary LastWill where
  arbitrary = LastWill <$> arbitrary <*> arbitrary <*> astr <*> astr <*> arbitrary

instance Arbitrary ProtocolLevel where arbitrary = arbitraryBoundedEnum

instance Arbitrary ConnectRequest where
  arbitrary = do
    _username <- mastr
    _password <- mastr
    _connID <- astr
    _cleanSession <- arbitrary
    _keepAlive <- arbitrary
    _lastWill <- arbitrary
    _properties <- arbitrary

    pure ConnectRequest{..}

mastr :: Gen (Maybe L.ByteString)
mastr = fmap (L.fromStrict . BC.pack . getUnicodeString) <$> arbitrary

astr :: Gen L.ByteString
astr = L.fromStrict . BC.pack . getUnicodeString <$> arbitrary

instance Arbitrary QoS where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary ConnACKFlags where
  arbitrary = ConnACKFlags <$> arbitrary <*> arbitrary <*> arbitrary
  shrink (ConnACKFlags b c pl)
    | null pl = []
    | otherwise = ConnACKFlags b c <$> shrink pl

instance Arbitrary PublishRequest where
  arbitrary = do
    _pubDup <- arbitrary
    _pubQoS <- arbitrary
    _pubRetain <- arbitrary
    _pubTopic <- astr
    _pubPktID <- if _pubQoS == QoS0 then pure 0 else arbitrary
    _pubBody <- astr
    _pubProps <- arbitrary
    pure PublishRequest{..}

instance Arbitrary PubACK where
  arbitrary = PubACK <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary PubREL where
  arbitrary = PubREL <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary PubREC where
  arbitrary = PubREC <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary PubCOMP where
  arbitrary = PubCOMP <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary SubscribeRequest where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> SubscribeRequest pid <$> vectorOf n sub <*> arbitrary
    where sub = liftA2 (,) astr arbitrary

  shrink (SubscribeRequest w s p) =
    if length s < 2 then []
    else [SubscribeRequest w (take 1 s) p' | p' <- shrinkList (:[]) p, length p > 1]

instance Arbitrary SubOptions where
  arbitrary = SubOptions <$> arbitraryBoundedEnum <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary SubErr where arbitrary = arbitraryBoundedEnum

instance Arbitrary SubscribeResponse where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> SubscribeResponse pid <$> vectorOf n arbitrary <*> arbitrary

  shrink (SubscribeResponse pid l props)
    | length l == 1 = []
    | otherwise = [SubscribeResponse pid sl props | sl <- shrinkList (:[]) l, not (null sl)]

instance Arbitrary UnsubscribeRequest where
  arbitrary = arbitrary >>= \pid -> choose (1,11) >>= \n -> UnsubscribeRequest pid <$> vectorOf n astr <*> arbitrary
  shrink (UnsubscribeRequest p l props)
    | length l == 1 = []
    | otherwise = [UnsubscribeRequest p sl props | sl <- shrinkList (:[]) l, not (null sl)]

instance Arbitrary UnsubStatus where arbitrary = arbitraryBoundedEnum

instance Arbitrary UnsubscribeResponse where
  arbitrary = UnsubscribeResponse <$> arbitrary <*> arbitrary <*> arbitrary

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

instance Arbitrary AuthRequest where
  arbitrary = AuthRequest <$> arbitrary <*> arbitrary

instance Arbitrary ConnACKRC where arbitrary = arbitraryBoundedEnum

instance Arbitrary DiscoReason where arbitrary = arbitraryBoundedEnum

instance Arbitrary DisconnectRequest where
  arbitrary = DisconnectRequest <$> arbitrary <*> arbitrary

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
    pure PingPkt, pure PongPkt,
    DisconnectPkt <$> arbitrary,
    AuthPkt <$> arbitrary
    ]
  shrink (SubACKPkt x)      = SubACKPkt <$> shrink x
  shrink (ConnACKPkt x)     = ConnACKPkt <$> shrink x
  shrink (UnsubscribePkt x) = UnsubscribePkt <$> shrink x
  shrink (SubscribePkt x)   = SubscribePkt <$> shrink x
  shrink _                  = []

-- | v311mask strips all the v5 specific bits from an MQTTPkt.
v311mask :: MQTTPkt -> MQTTPkt
v311mask (ConnPkt c@ConnectRequest{..}) = ConnPkt (c{_properties=mempty,
                                                     _password=mpw _username _password,
                                                     _lastWill=cl <$> _lastWill})
  where cl lw = lw{_willProps=mempty}
        mpw Nothing _ = Nothing
        mpw _ p       = p
v311mask (ConnACKPkt (ConnACKFlags a b _)) = ConnACKPkt (ConnACKFlags a b mempty)
v311mask (SubscribePkt (SubscribeRequest p s _)) = SubscribePkt (SubscribeRequest p c mempty)
  where c = map (\(k,SubOptions{..}) -> (k,subOptions{_subQoS=_subQoS})) s
v311mask (SubACKPkt (SubscribeResponse p s _)) = SubACKPkt (SubscribeResponse p s mempty)
v311mask (UnsubscribePkt (UnsubscribeRequest p l _)) = UnsubscribePkt (UnsubscribeRequest p l mempty)
v311mask (UnsubACKPkt (UnsubscribeResponse p _ _)) = UnsubACKPkt (UnsubscribeResponse p mempty mempty)
v311mask (PublishPkt req) = PublishPkt req{_pubProps=mempty}
v311mask (DisconnectPkt _) = DisconnectPkt (DisconnectRequest DiscoNormalDisconnection mempty)
v311mask (PubACKPkt (PubACK x _ _)) = PubACKPkt (PubACK x 0 mempty)
v311mask (PubRECPkt (PubREC x _ _)) = PubRECPkt (PubREC x 0 mempty)
v311mask (PubRELPkt (PubREL x _ _)) = PubRELPkt (PubREL x 0 mempty)
v311mask (PubCOMPPkt (PubCOMP x _ _)) = PubCOMPPkt (PubCOMP x 0 mempty)
v311mask x = x
