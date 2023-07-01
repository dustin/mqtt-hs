{-|
Module      : Network.MQTT.Types
Description : Parsers and serializers for MQTT.
Copyright   : (c) Dustin Sallings, 2019
License     : BSD3
Maintainer  : dustin@spy.net
Stability   : experimental

MQTT Types.
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Types (
  LastWill(..), MQTTPkt(..), QoS(..), qosFromInt,
  ConnectRequest(..), connectRequest, SessionReuse(..), ConnACKFlags(..), ConnACKRC(..),
  PublishRequest(..), PubACK(..), PubREC(..), PubREL(..), PubCOMP(..),
  ProtocolLevel(..), Property(..), AuthRequest(..),
  SubscribeRequest(..), SubOptions(..), subOptions, SubscribeResponse(..), SubErr(..),
  RetainHandling(..), DisconnectRequest(..),
  UnsubscribeRequest(..), UnsubscribeResponse(..), UnsubStatus(..), DiscoReason(..),
  PktID,
  parsePacket, ByteMe(toByteString), parseConnect,
  -- for testing
  encodeLength, parseHdrLen, parseProperty, parseProperties, bsProps,
  parseSubOptions, ByteSize(..)
  ) where

import           Control.Applicative             (liftA2, (<|>))
import           Control.Monad                   (replicateM, when)
import           Data.Attoparsec.Binary          (anyWord16be, anyWord32be)
import qualified Data.Attoparsec.ByteString      as AS
import qualified Data.Attoparsec.ByteString.Lazy as A
import           Data.Binary.Put                 (putWord32be, runPut)
import           Data.Bits                       (Bits (..), shiftL, testBit, (.&.), (.|.))
import qualified Data.ByteString.Lazy            as BL
import           Data.Foldable                   (asum)
import           Data.Functor                    (($>))
import           Data.Maybe                      (fromMaybe, isJust)
import           Data.Word                       (Word16, Word32, Word8)

-- | QoS values for publishing and subscribing.
data QoS = QoS0 | QoS1 | QoS2 deriving (Bounded, Enum, Eq, Show, Ord)

qosW :: QoS -> Word8
qosW = toEnum . fromEnum

wQos :: Word8 -> QoS
wQos = toEnum . fromIntegral

-- | Parse a valid QoS value from an Int.
qosFromInt :: Int -> Maybe QoS
qosFromInt 0 = Just QoS0
qosFromInt 1 = Just QoS1
qosFromInt 2 = Just QoS2
qosFromInt _ = Nothing

(≫) :: Bits a => a -> Int -> a
(≫) = shiftR

(≪) :: Bits a => a -> Int -> a
(≪) = shiftL

class ByteMe a where
  toBytes :: ProtocolLevel -> a -> [Word8]
  toBytes p = BL.unpack . toByteString p

  toByteString :: ProtocolLevel -> a -> BL.ByteString
  toByteString p = BL.pack . toBytes p

class ByteSize a where
  toByte :: a -> Word8
  fromByte :: Word8 -> a

boolBit :: Bool -> Word8
boolBit False = 0
boolBit True  = 1

parseHdrLen :: A.Parser Int
parseHdrLen = decodeVarInt

decodeVarInt :: A.Parser Int
decodeVarInt = go 0 1
  where
    go :: Int -> Int -> A.Parser Int
    go v m = do
      x <- A.anyWord8
      let a = fromIntegral (x .&. 127) * m + v
      if x .&. 128 /= 0
        then go a (m*128)
        else pure a

encodeLength :: Int -> [Word8]
encodeLength = encodeVarInt

encodeVarInt :: Int -> [Word8]
encodeVarInt n = go (n `quotRem` 128)
  where
    go (x,e)
      | x > 0 = en (e .|. 128) : go (x `quotRem` 128)
      | otherwise = [en e]

    en :: Int -> Word8
    en = toEnum

encodeWord8 :: Word8 -> BL.ByteString
encodeWord8 = BL.singleton

encodeWord16 :: Word16 -> BL.ByteString
encodeWord16 a = let (h,l) = a `quotRem` 256 in BL.pack [w h, w l]
    where w = toEnum . fromIntegral

encodeWord32 :: Word32 -> BL.ByteString
encodeWord32 = runPut . putWord32be

encodeBytes :: BL.ByteString -> BL.ByteString
encodeBytes x = twoByteLen x <> x

encodeUTF8 :: BL.ByteString -> BL.ByteString
encodeUTF8 = encodeBytes

encodeUTF8Pair :: BL.ByteString -> BL.ByteString -> BL.ByteString
encodeUTF8Pair x y = encodeUTF8 x <> encodeUTF8 y

twoByteLen :: BL.ByteString -> BL.ByteString
twoByteLen = encodeWord16 . fromIntegral . BL.length

blLength :: BL.ByteString -> BL.ByteString
blLength = BL.pack . encodeVarInt . fromIntegral . BL.length

withLength :: BL.ByteString -> BL.ByteString
withLength a = blLength a <> a

instance ByteMe BL.ByteString where
  toByteString _ a = (encodeWord16 . fromIntegral . BL.length) a <> a

-- | Property represents the various MQTT Properties that may sent or
-- received along with packets in MQTT 5.  For detailed use on when
-- and where to use them, consult with the MQTT 5.0 spec.
data Property = PropPayloadFormatIndicator Word8
              | PropMessageExpiryInterval Word32
              | PropContentType BL.ByteString
              | PropResponseTopic BL.ByteString
              | PropCorrelationData BL.ByteString
              | PropSubscriptionIdentifier Int
              | PropSessionExpiryInterval Word32
              | PropAssignedClientIdentifier BL.ByteString
              | PropServerKeepAlive Word16
              | PropAuthenticationMethod BL.ByteString
              | PropAuthenticationData BL.ByteString
              | PropRequestProblemInformation Word8
              | PropWillDelayInterval Word32
              | PropRequestResponseInformation Word8
              | PropResponseInformation BL.ByteString
              | PropServerReference BL.ByteString
              | PropReasonString BL.ByteString
              | PropReceiveMaximum Word16
              | PropTopicAliasMaximum Word16
              | PropTopicAlias Word16
              | PropMaximumQoS Word8
              | PropRetainAvailable Word8
              | PropUserProperty BL.ByteString BL.ByteString
              | PropMaximumPacketSize Word32
              | PropWildcardSubscriptionAvailable Word8
              | PropSubscriptionIdentifierAvailable Word8
              | PropSharedSubscriptionAvailable Word8
              deriving (Show, Eq)

peW8 :: Word8 -> Word8 -> BL.ByteString
peW8 i x = BL.singleton i <> encodeWord8 x

peW16 :: Word8 -> Word16 -> BL.ByteString
peW16 i x = BL.singleton i <> encodeWord16 x

peW32 :: Word8 -> Word32 -> BL.ByteString
peW32 i x = BL.singleton i <> encodeWord32 x

peUTF8 :: Word8 -> BL.ByteString -> BL.ByteString
peUTF8 i x = BL.singleton i <> encodeUTF8 x

peBin :: Word8 -> BL.ByteString -> BL.ByteString
peBin i x = BL.singleton i <> encodeBytes x

peVarInt :: Word8 -> Int -> BL.ByteString
peVarInt i x = BL.singleton i <> (BL.pack . encodeVarInt) x

instance ByteMe Property where
  toByteString _ (PropPayloadFormatIndicator x)          = peW8 0x01 x

  toByteString _ (PropMessageExpiryInterval x)           = peW32 0x02 x

  toByteString _ (PropContentType x)                     = peUTF8 0x03 x

  toByteString _ (PropResponseTopic x)                   = peUTF8 0x08 x

  toByteString _ (PropCorrelationData x)                 = peBin 0x09 x

  toByteString _ (PropSubscriptionIdentifier x)          = peVarInt 0x0b x

  toByteString _ (PropSessionExpiryInterval x)           = peW32 0x11 x

  toByteString _ (PropAssignedClientIdentifier x)        = peUTF8 0x12 x

  toByteString _ (PropServerKeepAlive x)                 = peW16 0x13 x

  toByteString _ (PropAuthenticationMethod x)            = peUTF8 0x15 x

  toByteString _ (PropAuthenticationData x)              = peBin 0x16 x

  toByteString _ (PropRequestProblemInformation x)       = peW8 0x17 x

  toByteString _ (PropWillDelayInterval x)               = peW32 0x18 x

  toByteString _ (PropRequestResponseInformation x)      = peW8 0x19 x

  toByteString _ (PropResponseInformation x)             = peUTF8 0x1a x

  toByteString _ (PropServerReference x)                 = peUTF8 0x1c x

  toByteString _ (PropReasonString x)                    = peUTF8 0x1f x

  toByteString _ (PropReceiveMaximum x)                  = peW16 0x21 x

  toByteString _ (PropTopicAliasMaximum x)               = peW16 0x22 x

  toByteString _ (PropTopicAlias x)                      = peW16 0x23 x

  toByteString _ (PropMaximumQoS x)                      = peW8 0x24 x

  toByteString _ (PropRetainAvailable x)                 = peW8 0x25 x

  toByteString _ (PropUserProperty k v)                  = BL.singleton 0x26 <> encodeUTF8Pair k v

  toByteString _ (PropMaximumPacketSize x)               = peW32 0x27 x

  toByteString _ (PropWildcardSubscriptionAvailable x)   = peW8 0x28 x

  toByteString _ (PropSubscriptionIdentifierAvailable x) = peW8 0x29 x

  toByteString _ (PropSharedSubscriptionAvailable x)     = peW8 0x2a x

parseProperty :: A.Parser Property
parseProperty = (A.word8 0x01 >> PropPayloadFormatIndicator <$> A.anyWord8)
                <|> (A.word8 0x02 >> PropMessageExpiryInterval <$> aWord32)
                <|> (A.word8 0x03 >> PropContentType <$> aString)
                <|> (A.word8 0x08 >> PropResponseTopic <$> aString)
                <|> (A.word8 0x09 >> PropCorrelationData <$> aString)
                <|> (A.word8 0x0b >> PropSubscriptionIdentifier <$> decodeVarInt)
                <|> (A.word8 0x11 >> PropSessionExpiryInterval <$> aWord32)
                <|> (A.word8 0x12 >> PropAssignedClientIdentifier <$> aString)
                <|> (A.word8 0x13 >> PropServerKeepAlive <$> aWord16)
                <|> (A.word8 0x15 >> PropAuthenticationMethod <$> aString)
                <|> (A.word8 0x16 >> PropAuthenticationData <$> aString)
                <|> (A.word8 0x17 >> PropRequestProblemInformation <$> A.anyWord8)
                <|> (A.word8 0x18 >> PropWillDelayInterval <$> aWord32)
                <|> (A.word8 0x19 >> PropRequestResponseInformation <$> A.anyWord8)
                <|> (A.word8 0x1a >> PropResponseInformation <$> aString)
                <|> (A.word8 0x1c >> PropServerReference <$> aString)
                <|> (A.word8 0x1f >> PropReasonString <$> aString)
                <|> (A.word8 0x21 >> PropReceiveMaximum <$> aWord16)
                <|> (A.word8 0x22 >> PropTopicAliasMaximum <$> aWord16)
                <|> (A.word8 0x23 >> PropTopicAlias <$> aWord16)
                <|> (A.word8 0x24 >> PropMaximumQoS <$> A.anyWord8)
                <|> (A.word8 0x25 >> PropRetainAvailable <$> A.anyWord8)
                <|> (A.word8 0x26 >> PropUserProperty <$> aString <*> aString)
                <|> (A.word8 0x27 >> PropMaximumPacketSize <$> aWord32)
                <|> (A.word8 0x28 >> PropWildcardSubscriptionAvailable <$> A.anyWord8)
                <|> (A.word8 0x29 >> PropSubscriptionIdentifierAvailable <$> A.anyWord8)
                <|> (A.word8 0x2a >> PropSharedSubscriptionAvailable <$> A.anyWord8)

bsProps :: ProtocolLevel -> [Property] -> BL.ByteString
bsProps Protocol311 _ = mempty
bsProps p l = let b = foldMap (toByteString p) l in
                (BL.pack . encodeLength . fromIntegral . BL.length) b <> b

parseProperties :: ProtocolLevel -> A.Parser [Property]
parseProperties Protocol311 = pure mempty
parseProperties Protocol50 = do
  len <- decodeVarInt
  either fail pure . AS.parseOnly (A.many' parseProperty) =<< A.take len

-- | MQTT Protocol Levels
data ProtocolLevel = Protocol311 -- ^ MQTT 3.1.1
                   | Protocol50  -- ^ MQTT 5.0
                   deriving(Bounded, Enum, Eq, Show)

instance ByteMe ProtocolLevel where
  toByteString _ Protocol311 = BL.singleton 4
  toByteString _ Protocol50  = BL.singleton 5

-- | An MQTT Will message.
data LastWill = LastWill {
  _willRetain  :: Bool
  , _willQoS   :: QoS
  , _willTopic :: BL.ByteString
  , _willMsg   :: BL.ByteString
  , _willProps :: [Property]
  } deriving(Eq, Show)

data ConnectRequest = ConnectRequest {
  _username         :: Maybe BL.ByteString
  , _password       :: Maybe BL.ByteString
  , _lastWill       :: Maybe LastWill
  , _cleanSession   :: Bool
  , _keepAlive      :: Word16
  , _connID         :: BL.ByteString
  , _connProperties :: [Property]
  } deriving (Eq, Show)

connectRequest :: ConnectRequest
connectRequest = ConnectRequest{_username=Nothing, _password=Nothing, _lastWill=Nothing,
                                _cleanSession=True, _keepAlive=300, _connID="",
                                _connProperties=mempty}

instance ByteMe ConnectRequest where
  toByteString prot ConnectRequest{..} = BL.singleton 0x10 <> withLength (val prot)
    where
      val :: ProtocolLevel -> BL.ByteString
      val Protocol311 = "\NUL\EOTMQTT\EOT" -- MQTT + Protocol311
                        <> BL.singleton connBits
                        <> encodeWord16 _keepAlive
                        <> toByteString prot _connID
                        <> lwt _lastWill
                        <> perhaps _username
                        <> if isJust _username then perhaps _password else ""

      val Protocol50 = "\NUL\EOTMQTT\ENQ" -- MQTT + Protocol50
                       <> BL.singleton connBits
                       <> encodeWord16 _keepAlive
                       <> bsProps prot _connProperties
                       <> toByteString prot _connID
                       <> lwt _lastWill
                       <> perhaps _username
                       <> perhaps _password

      connBits = hasu .|. hasp .|. willBits .|. clean
        where
          hasu = boolBit (isJust _username) ≪ 7
          hasp = boolBit ((prot == Protocol50 || isJust _username) && isJust _password) ≪ 6
          clean = boolBit _cleanSession ≪ 1
          willBits = case _lastWill of
                       Nothing           -> 0
                       Just LastWill{..} -> 4 .|. ((qosW _willQoS .&. 0x3) ≪ 3) .|. (boolBit _willRetain ≪ 5)

      lwt :: Maybe LastWill -> BL.ByteString
      lwt Nothing = mempty
      lwt (Just LastWill{..}) = bsProps prot _willProps
                                <> toByteString prot _willTopic
                                <> toByteString prot _willMsg

      perhaps :: Maybe BL.ByteString -> BL.ByteString
      perhaps = maybe "" (toByteString prot)

data MQTTPkt = ConnPkt ConnectRequest ProtocolLevel
             | ConnACKPkt ConnACKFlags
             | PublishPkt PublishRequest
             | PubACKPkt PubACK
             | PubRECPkt PubREC
             | PubRELPkt PubREL
             | PubCOMPPkt PubCOMP
             | SubscribePkt SubscribeRequest
             | SubACKPkt SubscribeResponse
             | UnsubscribePkt UnsubscribeRequest
             | UnsubACKPkt UnsubscribeResponse
             | PingPkt
             | PongPkt
             | DisconnectPkt DisconnectRequest
             | AuthPkt AuthRequest
  deriving (Eq, Show)

instance ByteMe MQTTPkt where
  toByteString p (ConnPkt x _)      = toByteString p x
  toByteString p (ConnACKPkt x)     = toByteString p x
  toByteString p (PublishPkt x)     = toByteString p x
  toByteString p (PubACKPkt x)      = toByteString p x
  toByteString p (PubRELPkt x)      = toByteString p x
  toByteString p (PubRECPkt x)      = toByteString p x
  toByteString p (PubCOMPPkt x)     = toByteString p x
  toByteString p (SubscribePkt x)   = toByteString p x
  toByteString p (SubACKPkt x)      = toByteString p x
  toByteString p (UnsubscribePkt x) = toByteString p x
  toByteString p (UnsubACKPkt x)    = toByteString p x
  toByteString _ PingPkt            = "\192\NUL"
  toByteString _ PongPkt            = "\208\NUL"
  toByteString p (DisconnectPkt x)  = toByteString p x
  toByteString p (AuthPkt x)        = toByteString p x

parsePacket :: ProtocolLevel -> A.Parser MQTTPkt
parsePacket p = asum [parseConnect, parseConnectACK,
                      parsePublish p, parsePubACK,
                      parsePubREC, parsePubREL, parsePubCOMP,
                      parseSubscribe p, parseSubACK p,
                      parseUnsubscribe p, parseUnsubACK p,
                      PingPkt <$ A.string "\192\NUL", PongPkt <$ A.string "\208\NUL",
                      parseDisconnect p,
                      parseAuth]

aWord16 :: A.Parser Word16
aWord16 = anyWord16be

aWord32 :: A.Parser Word32
aWord32 = anyWord32be

aString :: A.Parser BL.ByteString
aString = do
  n <- aWord16
  BL.fromStrict <$> A.take (fromIntegral n)

-- | Parse a CONNect packet.  This is useful when examining the
-- beginning of the stream as it allows you to determine the protocol
-- being used throughout the rest of the session.
parseConnect :: A.Parser MQTTPkt
parseConnect = do
  _ <- A.word8 0x10
  _ <- parseHdrLen
  _ <- A.string "\NUL\EOTMQTT" -- "MQTT"
  pl <- parseLevel

  connFlagBits <- A.anyWord8
  keepAlive <- aWord16
  props <- parseProperties pl
  cid <- aString
  lwt <- parseLwt pl connFlagBits
  u <- mstr (testBit connFlagBits 7)
  p <- mstr (testBit connFlagBits 6)

  pure $ ConnPkt ConnectRequest{_connID=cid, _username=u, _password=p,
                                _lastWill=lwt, _keepAlive=keepAlive,
                                _cleanSession=testBit connFlagBits 1,
                                _connProperties=props} pl

  where
    mstr :: Bool -> A.Parser (Maybe BL.ByteString)
    mstr False = pure Nothing
    mstr True  = Just <$> aString

    parseLevel = A.string "\EOT" $> Protocol311
                 <|> A.string "\ENQ" $> Protocol50

    parseLwt pl bits
      | testBit bits 2 = do
          props <- parseProperties pl
          top <- aString
          msg <- aString
          pure $ Just LastWill{_willTopic=top, _willMsg=msg,
                               _willRetain=testBit bits 5,
                               _willQoS=wQos $ (bits ≫ 3) .&. 0x3,
                               _willProps = props}
      | otherwise = pure Nothing

data ConnACKRC = ConnAccepted
  -- 3.1.1 codes
  | UnacceptableProtocol
  | IdentifierRejected
  | ServerUnavailable
  | BadCredentials
  | NotAuthorized
  -- 5.0 codes
  | ConnUnspecifiedError
  | ConnMalformedPacket
  | ConnProtocolError
  | ConnImplementationSpecificError
  | ConnUnsupportedProtocolVersion
  | ConnClientIdentifierNotValid
  | ConnBadUserNameOrPassword
  | ConnNotAuthorized
  | ConnServerUnavailable
  | ConnServerBusy
  | ConnBanned
  | ConnBadAuthenticationMethod
  | ConnTopicNameInvalid
  | ConnPacketTooLarge
  | ConnQuotaExceeded
  | ConnPayloadFormatInvalid
  | ConnRetainNotSupported
  | ConnQosNotSupported
  | ConnUseAnotherServer
  | ConnServerMoved
  | ConnConnectionRateExceeded
  deriving(Eq, Show, Bounded, Enum)

instance ByteSize ConnACKRC where

  toByte ConnAccepted                    = 0
  toByte UnacceptableProtocol            = 1
  toByte IdentifierRejected              = 2
  toByte ServerUnavailable               = 3
  toByte BadCredentials                  = 4
  toByte NotAuthorized                   = 5
  toByte ConnUnspecifiedError            = 0x80
  toByte ConnMalformedPacket             = 0x81
  toByte ConnProtocolError               = 0x82
  toByte ConnImplementationSpecificError = 0x83
  toByte ConnUnsupportedProtocolVersion  = 0x84
  toByte ConnClientIdentifierNotValid    = 0x85
  toByte ConnBadUserNameOrPassword       = 0x86
  toByte ConnNotAuthorized               = 0x87
  toByte ConnServerUnavailable           = 0x88
  toByte ConnServerBusy                  = 0x89
  toByte ConnBanned                      = 0x8a
  toByte ConnBadAuthenticationMethod     = 0x8c
  toByte ConnTopicNameInvalid            = 0x90
  toByte ConnPacketTooLarge              = 0x95
  toByte ConnQuotaExceeded               = 0x97
  toByte ConnPayloadFormatInvalid        = 0x99
  toByte ConnRetainNotSupported          = 0x9a
  toByte ConnQosNotSupported             = 0x9b
  toByte ConnUseAnotherServer            = 0x9c
  toByte ConnServerMoved                 = 0x9d
  toByte ConnConnectionRateExceeded      = 0x9f

  fromByte b = fromMaybe ConnUnspecifiedError $ lookup b connACKRev

connACKRev :: [(Word8, ConnACKRC)]
connACKRev = map (\w -> (toByte w, w)) [minBound..]

data SessionReuse = NewSession | ExistingSession deriving (Show, Eq, Bounded, Enum)

-- | Connection acknowledgment details.
data ConnACKFlags = ConnACKFlags SessionReuse ConnACKRC [Property] deriving (Eq, Show)

instance ByteMe ConnACKFlags where
  toBytes prot (ConnACKFlags sp rc props) =
    let pbytes = BL.unpack $ bsProps prot props in
      [0x20]
      <> encodeVarInt (2 + length pbytes)
      <>[ boolBit (sp /= NewSession), toByte rc] <> pbytes

parseConnectACK :: A.Parser MQTTPkt
parseConnectACK = do
  _ <- A.word8 0x20
  rl <- decodeVarInt -- remaining length
  when (rl < 2) $ fail "conn ack packet too short"
  ackFlags <- A.anyWord8
  rc <- A.anyWord8
  p <- parseProperties (if rl == 2 then Protocol311 else Protocol50)
  pure $ ConnACKPkt $ ConnACKFlags (sf $ testBit ackFlags 0) (fromByte rc) p

    where sf False = NewSession
          sf True  = ExistingSession

type PktID = Word16

data PublishRequest = PublishRequest{
  _pubDup      :: Bool
  , _pubQoS    :: QoS
  , _pubRetain :: Bool
  , _pubTopic  :: BL.ByteString
  , _pubPktID  :: PktID
  , _pubBody   :: BL.ByteString
  , _pubProps  :: [Property]
  } deriving(Eq, Show)

instance ByteMe PublishRequest where
  toByteString prot PublishRequest{..} =
    BL.singleton (0x30 .|. f) <> withLength val

    where f = (db ≪ 3) .|. (qb ≪ 1) .|. rb
          db = boolBit _pubDup
          qb = qosW _pubQoS .&. 0x3
          rb = boolBit _pubRetain
          pktid
            | _pubQoS == QoS0 = mempty
            | otherwise = encodeWord16 _pubPktID
          val = toByteString prot _pubTopic <> pktid <> bsProps prot _pubProps <> _pubBody

parsePublish :: ProtocolLevel -> A.Parser MQTTPkt
parsePublish prot = do
  w <- A.satisfy (\x -> x .&. 0xf0 == 0x30)
  plen <- parseHdrLen
  let _pubDup = w .&. 0x8 == 0x8
      _pubQoS = wQos $ (w ≫ 1) .&. 3
      _pubRetain = w .&. 1 == 1
  _pubTopic <- aString
  _pubPktID <- if _pubQoS == QoS0 then pure 0 else aWord16
  _pubProps <- parseProperties prot
  _pubBody <- BL.fromStrict <$> A.take (plen - fromIntegral (BL.length _pubTopic) - 2
                                        - qlen _pubQoS - propLen prot _pubProps )
  pure $ PublishPkt PublishRequest{..}

  where qlen QoS0 = 0
        qlen _    = 2

-- | How to process retained messages on subscriptions.
data RetainHandling = SendOnSubscribe       -- ^ Send existing retained messages to a new client.
                    | SendOnSubscribeNew    -- ^ Send existing retained messages that have not yet been sent.
                    | DoNotSendOnSubscribe  -- ^ Don't send existing retained messages.
  deriving (Eq, Show, Bounded, Enum)

-- | Options used at subscribe time to define how to handle incoming messages.
data SubOptions = SubOptions{
  _retainHandling      :: RetainHandling  -- ^ How to handle existing retained messages.
  , _retainAsPublished :: Bool            -- ^ If true, retain is propagated on subscribe.
  , _noLocal           :: Bool            -- ^ If true, do not send messages initiated from this client back.
  , _subQoS            :: QoS             -- ^ Maximum QoS to use for this subscription.
  } deriving(Eq, Show)

-- | Reasonable subscription option defaults at 'QoS0'.
subOptions :: SubOptions
subOptions = SubOptions{_retainHandling=SendOnSubscribe,
                         _retainAsPublished=False,
                         _noLocal=False,
                         _subQoS=QoS0}

instance ByteMe SubOptions where
  toByteString _ SubOptions{..} = BL.singleton (rh .|. rap .|. nl .|. q)

    where
      rh = case _retainHandling of
             SendOnSubscribeNew   -> 0x10
             DoNotSendOnSubscribe -> 0x20
             _                    -> 0
      rap
        | _retainAsPublished = 0x08
        | otherwise = 0
      nl
        | _noLocal = 0x04
        | otherwise = 0
      q = qosW _subQoS

parseSubOptions :: A.Parser SubOptions
parseSubOptions = do
  w <- A.anyWord8
  let rh = case w ≫ 4 of
             1 -> SendOnSubscribeNew
             2 -> DoNotSendOnSubscribe
             _ -> SendOnSubscribe

  pure $ SubOptions{
    _retainHandling=rh,
    _retainAsPublished=testBit w 3,
    _noLocal=testBit w 2,
    _subQoS=wQos (w .&. 0x3)}

subOptionsBytes :: ProtocolLevel -> [(BL.ByteString, SubOptions)] -> BL.ByteString
subOptionsBytes prot = foldMap (\(bs,so) -> toByteString prot bs <> toByteString prot so)

data SubscribeRequest = SubscribeRequest PktID [(BL.ByteString, SubOptions)] [Property]
                      deriving(Eq, Show)

instance ByteMe SubscribeRequest where
  toByteString prot (SubscribeRequest pid sreq props) =
    BL.singleton 0x82 <> withLength (encodeWord16 pid <> bsProps prot props <> subOptionsBytes prot sreq)

data PubACK = PubACK PktID Word8 [Property] deriving(Eq, Show)

bsPubSeg :: ProtocolLevel -> Word8 -> Word16 -> Word8 -> [Property] -> BL.ByteString
bsPubSeg Protocol311 h pid _ _ = BL.singleton h <> withLength (encodeWord16 pid)
bsPubSeg Protocol50 h pid st props = BL.singleton h
                                     <> withLength (encodeWord16 pid
                                                    <> BL.singleton st
                                                    <> mprop props)
    where
      mprop [] = mempty
      mprop p  = bsProps Protocol50 p

instance ByteMe PubACK where
  toByteString prot (PubACK pid st props) = bsPubSeg prot 0x40 pid st props

-- Common parser for all of the pub parts for q>0 handling:  (PubACK, PubREC, PubREL, PubCOMP)
parsePubSeg :: Word8 -> (a -> MQTTPkt) -> (PktID -> Word8 -> [Property] -> a) -> A.Parser MQTTPkt
parsePubSeg i cona conb = do
  _ <- A.word8 i
  rl <- parseHdrLen
  mid <- aWord16
  st <- if rl > 2 then A.anyWord8 else pure 0
  props <- if rl > 3 then parseProperties Protocol50 else pure mempty
  pure $ cona (conb mid st props)

parsePubACK :: A.Parser MQTTPkt
parsePubACK = parsePubSeg 0x40 PubACKPkt PubACK

data PubREC = PubREC PktID Word8 [Property] deriving(Eq, Show)

instance ByteMe PubREC where
  toByteString prot (PubREC pid st props) = bsPubSeg prot 0x50 pid st props

parsePubREC :: A.Parser MQTTPkt
parsePubREC = parsePubSeg 0x50 PubRECPkt PubREC

data PubREL = PubREL PktID Word8 [Property] deriving(Eq, Show)

instance ByteMe PubREL where
  toByteString prot (PubREL pid st props) = bsPubSeg prot 0x62 pid st props

parsePubREL :: A.Parser MQTTPkt
parsePubREL = parsePubSeg 0x62 PubRELPkt PubREL

data PubCOMP = PubCOMP PktID Word8 [Property] deriving(Eq, Show)

instance ByteMe PubCOMP where
  toByteString prot (PubCOMP pid st props) = bsPubSeg prot 0x70 pid st props

parsePubCOMP :: A.Parser MQTTPkt
parsePubCOMP = parsePubSeg 0x70 PubCOMPPkt PubCOMP

-- Common header bits for subscribe, unsubscribe, and the sub acks.
parseSubHdr :: Word8 -> ProtocolLevel -> A.Parser a -> A.Parser (PktID, [Property], a)
parseSubHdr b prot p = do
  _ <- A.word8 b
  hl <- parseHdrLen
  pid <- aWord16
  props <- parseProperties prot
  content <- A.take (fromIntegral hl - 2 - propLen prot props)
  a <- subp content
  pure (pid, props, a)

    where subp = either fail pure . AS.parseOnly p

parseSubscribe :: ProtocolLevel -> A.Parser MQTTPkt
parseSubscribe prot = do
  (pid, props, subs) <- parseSubHdr 0x82 prot $ A.many1 (liftA2 (,) aString parseSubOptions)
  pure $ SubscribePkt (SubscribeRequest pid subs props)

data SubscribeResponse = SubscribeResponse PktID [Either SubErr QoS] [Property] deriving (Eq, Show)

instance ByteMe SubscribeResponse where
  toByteString prot (SubscribeResponse pid sres props) =
    BL.singleton 0x90 <> withLength (encodeWord16 pid <> bsProps prot props <> BL.pack (b <$> sres))

    where
      b (Left SubErrUnspecifiedError)                    =  0x80
      b (Left SubErrImplementationSpecificError)         =  0x83
      b (Left SubErrNotAuthorized)                       =  0x87
      b (Left SubErrTopicFilterInvalid)                  =  0x8F
      b (Left SubErrPacketIdentifierInUse)               =  0x91
      b (Left SubErrQuotaExceeded)                       =  0x97
      b (Left SubErrSharedSubscriptionsNotSupported)     =  0x9E
      b (Left SubErrSubscriptionIdentifiersNotSupported) =  0xA1
      b (Left SubErrWildcardSubscriptionsNotSupported)   =  0xA2
      b (Right q)                                        = qosW q

propLen :: ProtocolLevel -> [Property] -> Int
propLen Protocol311 _ = 0
propLen prot props    = fromIntegral $ BL.length (bsProps prot props)

data SubErr = SubErrUnspecifiedError
  | SubErrImplementationSpecificError
  | SubErrNotAuthorized
  | SubErrTopicFilterInvalid
  | SubErrPacketIdentifierInUse
  | SubErrQuotaExceeded
  | SubErrSharedSubscriptionsNotSupported
  | SubErrSubscriptionIdentifiersNotSupported
  | SubErrWildcardSubscriptionsNotSupported
  deriving (Eq, Show, Bounded, Enum)

parseSubACK :: ProtocolLevel -> A.Parser MQTTPkt
parseSubACK prot = do
  (pid, props, res) <- parseSubHdr 0x90 prot $ A.many1 (p <$> A.anyWord8)
  pure $ SubACKPkt (SubscribeResponse pid res props)

  where
    p 0x80 = Left SubErrUnspecifiedError
    p 0x83 = Left SubErrImplementationSpecificError
    p 0x87 = Left SubErrNotAuthorized
    p 0x8F = Left SubErrTopicFilterInvalid
    p 0x91 = Left SubErrPacketIdentifierInUse
    p 0x97 = Left SubErrQuotaExceeded
    p 0x9E = Left SubErrSharedSubscriptionsNotSupported
    p 0xA1 = Left SubErrSubscriptionIdentifiersNotSupported
    p 0xA2 = Left SubErrWildcardSubscriptionsNotSupported
    p x    = Right (wQos x)

data UnsubscribeRequest = UnsubscribeRequest PktID [BL.ByteString] [Property]
                        deriving(Eq, Show)

instance ByteMe UnsubscribeRequest where
  toByteString prot (UnsubscribeRequest pid sreq props) =
    BL.singleton 0xa2
    <> withLength (encodeWord16 pid <> bsProps prot props <> mconcat (toByteString prot <$> sreq))

parseUnsubscribe :: ProtocolLevel -> A.Parser MQTTPkt
parseUnsubscribe prot = do
  (pid, props, subs) <- parseSubHdr 0xa2 prot $ A.many1 aString
  pure $ UnsubscribePkt (UnsubscribeRequest pid subs props)

data UnsubStatus = UnsubSuccess
                 | UnsubNoSubscriptionExisted
                 | UnsubUnspecifiedError
                 | UnsubImplementationSpecificError
                 | UnsubNotAuthorized
                 | UnsubTopicFilterInvalid
                 | UnsubPacketIdentifierInUse
                 deriving(Show, Eq, Bounded, Enum)

instance ByteMe UnsubStatus where
  toByteString _ UnsubSuccess                     = BL.singleton 0x00
  toByteString _ UnsubNoSubscriptionExisted       = BL.singleton 0x11
  toByteString _ UnsubUnspecifiedError            = BL.singleton 0x80
  toByteString _ UnsubImplementationSpecificError = BL.singleton 0x83
  toByteString _ UnsubNotAuthorized               = BL.singleton 0x87
  toByteString _ UnsubTopicFilterInvalid          = BL.singleton 0x8F
  toByteString _ UnsubPacketIdentifierInUse       = BL.singleton 0x91

data UnsubscribeResponse = UnsubscribeResponse PktID [Property] [UnsubStatus] deriving(Eq, Show)

instance ByteMe UnsubscribeResponse where
  toByteString Protocol311 (UnsubscribeResponse pid _ _) =
    BL.singleton 0xb0 <> withLength (encodeWord16 pid)

  toByteString Protocol50 (UnsubscribeResponse pid props res) =
    BL.singleton 0xb0 <> withLength (encodeWord16 pid
                                      <> bsProps Protocol50 props
                                      <> mconcat (fmap (toByteString Protocol50) res))

parseUnsubACK :: ProtocolLevel -> A.Parser MQTTPkt
parseUnsubACK Protocol311 = do
  _ <- A.word8 0xb0
  _ <- parseHdrLen
  pid <- aWord16
  pure $ UnsubACKPkt (UnsubscribeResponse pid mempty mempty)

parseUnsubACK Protocol50 = do
  _ <- A.word8 0xb0
  rl <- parseHdrLen
  pid <- aWord16
  props <- parseProperties Protocol50
  res <- replicateM (rl - propLen Protocol50 props - 2) unsubACK
  pure $ UnsubACKPkt (UnsubscribeResponse pid props res)

  where
    unsubACK :: A.Parser UnsubStatus
    unsubACK = (UnsubSuccess <$ A.word8 0x00)
               <|> (UnsubNoSubscriptionExisted <$ A.word8 0x11)
               <|> (UnsubUnspecifiedError <$ A.word8 0x80)
               <|> (UnsubImplementationSpecificError <$ A.word8 0x83)
               <|> (UnsubNotAuthorized <$ A.word8 0x87)
               <|> (UnsubTopicFilterInvalid <$ A.word8 0x8F)
               <|> (UnsubPacketIdentifierInUse <$ A.word8 0x91)

data AuthRequest = AuthRequest Word8 [Property] deriving (Eq, Show)

instance ByteMe AuthRequest where
  toByteString prot (AuthRequest i props) =
    BL.singleton 0xf0 <> withLength (BL.singleton i <> bsProps prot props)

parseAuth :: A.Parser MQTTPkt
parseAuth = do
  _ <- A.word8 0xf0
  _ <- parseHdrLen
  r <- AuthRequest <$> A.anyWord8 <*> parseProperties Protocol50
  pure $ AuthPkt r

data DiscoReason = DiscoNormalDisconnection
  | DiscoDisconnectWithWill
  | DiscoUnspecifiedError
  | DiscoMalformedPacket
  | DiscoProtocolError
  | DiscoImplementationSpecificError
  | DiscoNotAuthorized
  | DiscoServerBusy
  | DiscoServershuttingDown
  | DiscoKeepAliveTimeout
  | DiscoSessiontakenOver
  | DiscoTopicFilterInvalid
  | DiscoTopicNameInvalid
  | DiscoReceiveMaximumExceeded
  | DiscoTopicAliasInvalid
  | DiscoPacketTooLarge
  | DiscoMessageRateTooHigh
  | DiscoQuotaExceeded
  | DiscoAdministrativeAction
  | DiscoPayloadFormatInvalid
  | DiscoRetainNotSupported
  | DiscoQoSNotSupported
  | DiscoUseAnotherServer
  | DiscoServerMoved
  | DiscoSharedSubscriptionsNotSupported
  | DiscoConnectionRateExceeded
  | DiscoMaximumConnectTime
  | DiscoSubscriptionIdentifiersNotSupported
  | DiscoWildcardSubscriptionsNotSupported
  deriving (Show, Eq, Bounded, Enum)

instance ByteSize DiscoReason where

  toByte DiscoNormalDisconnection                 = 0x00
  toByte DiscoDisconnectWithWill                  = 0x04
  toByte DiscoUnspecifiedError                    = 0x80
  toByte DiscoMalformedPacket                     = 0x81
  toByte DiscoProtocolError                       = 0x82
  toByte DiscoImplementationSpecificError         = 0x83
  toByte DiscoNotAuthorized                       = 0x87
  toByte DiscoServerBusy                          = 0x89
  toByte DiscoServershuttingDown                  = 0x8B
  toByte DiscoKeepAliveTimeout                    = 0x8D
  toByte DiscoSessiontakenOver                    = 0x8e
  toByte DiscoTopicFilterInvalid                  = 0x8f
  toByte DiscoTopicNameInvalid                    = 0x90
  toByte DiscoReceiveMaximumExceeded              = 0x93
  toByte DiscoTopicAliasInvalid                   = 0x94
  toByte DiscoPacketTooLarge                      = 0x95
  toByte DiscoMessageRateTooHigh                  = 0x96
  toByte DiscoQuotaExceeded                       = 0x97
  toByte DiscoAdministrativeAction                = 0x98
  toByte DiscoPayloadFormatInvalid                = 0x99
  toByte DiscoRetainNotSupported                  = 0x9a
  toByte DiscoQoSNotSupported                     = 0x9b
  toByte DiscoUseAnotherServer                    = 0x9c
  toByte DiscoServerMoved                         = 0x9d
  toByte DiscoSharedSubscriptionsNotSupported     = 0x9e
  toByte DiscoConnectionRateExceeded              = 0x9f
  toByte DiscoMaximumConnectTime                  = 0xa0
  toByte DiscoSubscriptionIdentifiersNotSupported = 0xa1
  toByte DiscoWildcardSubscriptionsNotSupported   = 0xa2

  fromByte w = fromMaybe DiscoMalformedPacket $ lookup w discoReasonRev

discoReasonRev :: [(Word8, DiscoReason)]
discoReasonRev = map (\w -> (toByte w, w)) [minBound..]

data DisconnectRequest = DisconnectRequest DiscoReason [Property] deriving (Eq, Show)

instance ByteMe DisconnectRequest where
  toByteString Protocol311 _ = "\224\NUL"

  toByteString Protocol50 (DisconnectRequest r props) =
    BL.singleton 0xe0 <> withLength (BL.singleton (toByte r) <> bsProps Protocol50 props)

parseDisconnect :: ProtocolLevel -> A.Parser MQTTPkt
parseDisconnect Protocol311 = do
  req <- DisconnectRequest DiscoNormalDisconnection mempty <$ A.string "\224\NUL"
  pure $ DisconnectPkt req

parseDisconnect Protocol50 = do
  _ <- A.word8 0xe0
  rl <- parseHdrLen
  r <- A.anyWord8
  props <- if rl > 1 then parseProperties Protocol50 else pure mempty

  pure $ DisconnectPkt (DisconnectRequest (fromByte r) props)
