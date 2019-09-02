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
  LastWill(..), MQTTPkt(..), QoS(..),
  ConnectRequest(..), connectRequest, ConnACKFlags(..), ConnACKRC(..),
  PublishRequest(..), PubACK(..), PubREC(..), PubREL(..), PubCOMP(..),
  ProtocolLevel(..), Property(..), Properties(..),
  SubscribeRequest(..), SubscribeResponse(..),
  UnsubscribeRequest(..), UnsubscribeResponse(..),
  parsePacket, ByteMe(toByteString),
  -- for testing
  encodeLength, parseHdrLen, connACKRC, parseProperty, parseProperties
  ) where

import           Control.Applicative             (liftA2, (<|>))
import           Control.Monad                   (replicateM)
import           Data.Attoparsec.Binary          (anyWord16be, anyWord32be)
import qualified Data.Attoparsec.ByteString.Lazy as A
import           Data.Binary.Put                 (putWord32be, runPut)
import           Data.Bits                       (Bits (..), shiftL, testBit,
                                                  (.&.), (.|.))
import           Data.Functor               (($>))
import qualified Data.ByteString.Lazy            as BL
import           Data.Maybe                      (isJust)
import           Data.Word                       (Word16, Word32, Word8)

-- | QoS values for publishing and subscribing.
data QoS = QoS0 | QoS1 | QoS2 deriving (Bounded, Enum, Eq, Show)

qosW :: QoS -> Word8
qosW = toEnum.fromEnum

wQos :: Word8 -> QoS
wQos = toEnum.fromEnum

(≫) :: Bits a => a -> Int -> a
(≫) = shiftR

(≪) :: Bits a => a -> Int -> a
(≪) = shiftL

class ByteMe a where
  toBytes :: a -> [Word8]
  toBytes = BL.unpack . toByteString
  toByteString :: a -> BL.ByteString
  toByteString = BL.pack . toBytes

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
      let a = fromEnum (x .&. 127) * m + v
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
    where w = toEnum.fromEnum

encodeWord32 :: Word32 -> BL.ByteString
encodeWord32 = runPut . putWord32be

encodeBytes :: BL.ByteString -> BL.ByteString
encodeBytes x = twoByteLen x <> x

encodeUTF8 :: BL.ByteString -> BL.ByteString
encodeUTF8 = encodeBytes

encodeUTF8Pair :: BL.ByteString -> BL.ByteString -> BL.ByteString
encodeUTF8Pair x y = encodeUTF8 x <> encodeUTF8 y

twoByteLen :: BL.ByteString -> BL.ByteString
twoByteLen = encodeWord16 . toEnum . fromEnum . BL.length

blLength :: BL.ByteString -> BL.ByteString
blLength = BL.pack . encodeVarInt . fromEnum . BL.length

withLength :: BL.ByteString -> BL.ByteString
withLength a = blLength a <> a

instance ByteMe BL.ByteString where
  toByteString a = (encodeWord16 . toEnum . fromEnum . BL.length) a <> a

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
  toByteString (PropPayloadFormatIndicator x)          = peW8 0x01 x

  toByteString (PropMessageExpiryInterval x)           = peW32 0x02 x

  toByteString (PropContentType x)                     = peUTF8 0x03 x

  toByteString (PropResponseTopic x)                   = peUTF8 0x08 x

  toByteString (PropCorrelationData x)                 = peBin 0x09 x

  toByteString (PropSubscriptionIdentifier x)          = peVarInt 0x0b x

  toByteString (PropSessionExpiryInterval x)           = peW32 0x11 x

  toByteString (PropAssignedClientIdentifier x)        = peUTF8 0x12 x

  toByteString (PropServerKeepAlive x)                 = peW16 0x13 x

  toByteString (PropAuthenticationMethod x)            = peUTF8 0x15 x

  toByteString (PropAuthenticationData x)              = peBin 0x16 x

  toByteString (PropRequestProblemInformation x)       = peW8 0x17 x

  toByteString (PropWillDelayInterval x)               = peW32 0x18 x

  toByteString (PropRequestResponseInformation x)      = peW8 0x19 x

  toByteString (PropResponseInformation x)             = peUTF8 0x1a x

  toByteString (PropServerReference x)                 = peUTF8 0x1c x

  toByteString (PropReasonString x)                    = peUTF8 0x1f x

  toByteString (PropReceiveMaximum x)                  = peW16 0x21 x

  toByteString (PropTopicAliasMaximum x)               = peW16 0x22 x

  toByteString (PropTopicAlias x)                      = peW16 0x23 x

  toByteString (PropMaximumQoS x)                      = peW8 0x24 x

  toByteString (PropRetainAvailable x)                 = peW8 0x25 x

  toByteString (PropUserProperty k v)                  = BL.singleton 0x26 <> encodeUTF8Pair k v

  toByteString (PropMaximumPacketSize x)               = peW32 0x27 x

  toByteString (PropWildcardSubscriptionAvailable x)   = peW8 0x28 x

  toByteString (PropSubscriptionIdentifierAvailable x) = peW8 0x29 x

  toByteString (PropSharedSubscriptionAvailable x)     = peW8 0x2a x

parseProperty :: A.Parser Property
parseProperty = do
  A.word8 0x01 >> PropPayloadFormatIndicator <$> A.anyWord8
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

newtype Properties = Properties [Property] deriving(Eq, Show)

instance ByteMe Properties where
  toByteString (Properties l) = let b = (mconcat . map toByteString) l in
                                  (BL.pack . encodeLength . fromEnum . BL.length) b <> b

parseProperties :: A.Parser Properties
parseProperties = do
  len <- decodeVarInt
  props <- A.take len
  Properties <$> subs props

  where
    subs d = case A.parseOnly (A.many' parseProperty) d of
               Left x  -> fail x
               Right x -> pure x

data ProtocolLevel = Protocol311
                   | Protocol50 deriving(Bounded, Enum, Eq, Show)

instance ByteMe ProtocolLevel where toByteString _ = BL.singleton 4

-- | An MQTT Will message.
data LastWill = LastWill {
  _willRetain  :: Bool
  , _willQoS   :: QoS
  , _willTopic :: BL.ByteString
  , _willMsg   :: BL.ByteString
  } deriving(Eq, Show)

data ConnectRequest = ConnectRequest {
  _username       :: Maybe BL.ByteString
  , _password     :: Maybe BL.ByteString
  , _lastWill     :: Maybe LastWill
  , _cleanSession :: Bool
  , _keepAlive    :: Word16
  , _connID       :: BL.ByteString
  , _connLvl      :: ProtocolLevel
  , _properties   :: Properties
  } deriving (Eq, Show)

connectRequest :: ConnectRequest
connectRequest = ConnectRequest{_username=Nothing, _password=Nothing, _lastWill=Nothing,
                                _cleanSession=True, _keepAlive=300, _connID="", _connLvl=Protocol311,
                                _properties=Properties []}

instance ByteMe ConnectRequest where
  toByteString ConnectRequest{..} = BL.singleton 0x10
                                    <> withLength (val _connLvl)
    where
      val :: ProtocolLevel -> BL.ByteString
      val Protocol311 = "\NUL\EOTMQTT\EOT" -- MQTT + Protocol311
                        <> common

      val Protocol50 = "\NUL\EOTMQTT\ENQ" -- MQTT + Protocol50
                       <> common
                       <> toByteString _properties

      common = BL.singleton connBits
               <> encodeWord16 _keepAlive
               <> toByteString _connID
               <> lwt _lastWill
               <> perhaps _username
               <> perhaps _password


      connBits = hasu .|. hasp .|. willBits .|. clean
        where
          hasu = boolBit (isJust _username) ≪ 7
          hasp = boolBit (isJust _password) ≪ 6
          clean = boolBit _cleanSession ≪ 1
          willBits = case _lastWill of
                       Nothing -> 0
                       Just LastWill{..} -> 4 .|. ((qosW _willQoS .&. 0x3) ≪ 3) .|. (boolBit _willRetain ≪ 5)

      lwt :: Maybe LastWill -> BL.ByteString
      lwt Nothing = mempty
      lwt (Just LastWill{..}) = toByteString _willTopic <> toByteString _willMsg

      perhaps :: Maybe BL.ByteString -> BL.ByteString
      perhaps Nothing  = ""
      perhaps (Just s) = toByteString s

data MQTTPkt = ConnPkt ConnectRequest
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
             | DisconnectPkt
  deriving (Eq, Show)

instance ByteMe MQTTPkt where
  toByteString (ConnPkt x)        = toByteString x
  toByteString (ConnACKPkt x)     = toByteString x
  toByteString (PublishPkt x)     = toByteString x
  toByteString (PubACKPkt x)      = toByteString x
  toByteString (PubRELPkt x)      = toByteString x
  toByteString (PubRECPkt x)      = toByteString x
  toByteString (PubCOMPPkt x)     = toByteString x
  toByteString (SubscribePkt x)   = toByteString x
  toByteString (SubACKPkt x)      = toByteString x
  toByteString (UnsubscribePkt x) = toByteString x
  toByteString (UnsubACKPkt x)    = toByteString x
  toByteString PingPkt            = "\192\NUL"
  toByteString PongPkt            = "\208\NUL"
  toByteString DisconnectPkt      = "\224\NUL"

parsePacket :: A.Parser MQTTPkt
parsePacket = parseConnect <|> parseConnectACK
              <|> parsePublish <|> parsePubACK
              <|> parsePubREC <|> parsePubREL <|> parsePubCOMP
              <|> parseSubscribe <|> parseSubACK
              <|> parseUnsubscribe <|> parseUnsubACK
              <|> PingPkt <$ A.string "\192\NUL" <|> PongPkt <$ A.string "\208\NUL"
              <|> DisconnectPkt <$ A.string "\224\NUL"

aWord16 :: A.Parser Word16
aWord16 = anyWord16be

aWord32 :: A.Parser Word32
aWord32 = anyWord32be

aString :: A.Parser BL.ByteString
aString = do
  n <- aWord16
  s <- A.take (fromEnum n)
  pure $ BL.fromStrict s

parseConnect :: A.Parser MQTTPkt
parseConnect = do
  _ <- A.word8 0x10
  _ <- parseHdrLen
  _ <- A.string "\NUL\EOTMQTT" -- "MQTT"
  pl <- parseLevel

  connFlagBits <- A.anyWord8
  keepAlive <- aWord16
  cid <- aString
  lwt <- parseLwt connFlagBits
  u <- mstr (testBit connFlagBits 7)
  p <- mstr (testBit connFlagBits 6)

  props <- parseProps pl

  pure $ ConnPkt ConnectRequest{_connID=cid, _username=u, _password=p,
                                _lastWill=lwt, _keepAlive=keepAlive,
                                _cleanSession=testBit connFlagBits 1,
                                _connLvl=pl,
                                _properties=props}

  where
    mstr :: Bool -> A.Parser (Maybe BL.ByteString)
    mstr False = pure Nothing
    mstr True  = Just <$> aString

    parseLevel = A.string "\EOT" $> Protocol311
                 <|> A.string "\ENQ" $> Protocol50

    parseProps Protocol311 = pure $ Properties []
    parseProps Protocol50  = parseProperties

    parseLwt bits
      | testBit bits 2 = do
          top <- aString
          msg <- aString
          pure $ Just LastWill{_willTopic=top, _willMsg=msg,
                               _willRetain=testBit bits 5,
                               _willQoS=wQos $ (bits ≫ 3) .&. 0x3}
      | otherwise = pure Nothing

data ConnACKRC = ConnAccepted | UnacceptableProtocol
               | IdentifierRejected | ServerUnavailable
               | BadCredentials | NotAuthorized
               | InvalidConnACKRC Word8 deriving(Eq, Show)

connACKRC :: Word8 -> ConnACKRC
connACKRC 0 = ConnAccepted
connACKRC 1 = UnacceptableProtocol
connACKRC 2 = IdentifierRejected
connACKRC 3 = ServerUnavailable
connACKRC 4 = BadCredentials
connACKRC 5 = NotAuthorized
connACKRC x = InvalidConnACKRC x

connACKVal :: ConnACKRC -> Word8
connACKVal ConnAccepted         = 0
connACKVal UnacceptableProtocol = 1
connACKVal IdentifierRejected   = 2
connACKVal ServerUnavailable    = 3
connACKVal BadCredentials       = 4
connACKVal NotAuthorized        = 5
connACKVal (InvalidConnACKRC x) = x

data ConnACKFlags = ConnACKFlags Bool ConnACKRC deriving (Eq, Show)

instance ByteMe ConnACKFlags where
  toBytes (ConnACKFlags sp rc) = [0x20, 2, boolBit sp, connACKVal rc]

parseConnectACK :: A.Parser MQTTPkt
parseConnectACK = do
  _ <- A.word8 0x20
  _ <- A.word8 2 -- two bytes left
  ackFlags <- A.anyWord8
  rc <- A.anyWord8
  pure $ ConnACKPkt $ ConnACKFlags (testBit ackFlags 0) (connACKRC rc)

data PublishRequest = PublishRequest{
  _pubDup      :: Bool
  , _pubQoS    :: QoS
  , _pubRetain :: Bool
  , _pubTopic  :: BL.ByteString
  , _pubPktID  :: Word16
  , _pubBody   :: BL.ByteString
  } deriving(Eq, Show)

instance ByteMe PublishRequest where
  toByteString PublishRequest{..} = BL.singleton (0x30 .|. f)
                                    <> withLength val
    where f = (db ≪ 3) .|. (qb ≪ 1) .|. rb
          db = boolBit _pubDup
          qb = qosW _pubQoS .&. 0x3
          rb = boolBit _pubRetain
          pktid
            | _pubQoS == QoS0 = mempty
            | otherwise = encodeWord16 _pubPktID
          val = toByteString _pubTopic <> pktid <> _pubBody

parsePublish :: A.Parser MQTTPkt
parsePublish = do
  w <- A.satisfy (\x -> x .&. 0xf0 == 0x30)
  plen <- parseHdrLen
  let _pubDup = w .&. 0x8 == 0x8
      _pubQoS = wQos $ (w ≫ 1) .&. 3
      _pubRetain = w .&. 1 == 1
  _pubTopic <- aString
  _pubPktID <- if _pubQoS == QoS0 then pure 0 else aWord16
  _pubBody <- BL.fromStrict <$> A.take (plen - (fromEnum $ BL.length _pubTopic) - 2 - qlen _pubQoS)
  pure $ PublishPkt PublishRequest{..}

  where qlen QoS0 = 0
        qlen _    = 2

data SubscribeRequest = SubscribeRequest Word16 [(BL.ByteString, QoS)]
                      deriving(Eq, Show)

instance ByteMe SubscribeRequest where
  toByteString (SubscribeRequest pid sreq) =
    BL.singleton 0x82
    <> withLength (encodeWord16 pid <> reqs)
    where reqs = (BL.concat . map (\(bs,q) -> toByteString bs <> BL.singleton (qosW q))) sreq

newtype PubACK = PubACK Word16 deriving(Eq, Show)

instance ByteMe PubACK where
  toByteString (PubACK pid) = BL.singleton 0x40 <> withLength (encodeWord16 pid)

parsePubACK :: A.Parser MQTTPkt
parsePubACK = do
  _ <- A.word8 0x40
  _ <- parseHdrLen
  PubACKPkt . PubACK <$> aWord16

newtype PubREC = PubREC Word16 deriving(Eq, Show)

instance ByteMe PubREC where
  toByteString (PubREC pid) = BL.singleton 0x50 <> withLength (encodeWord16 pid)

parsePubREC :: A.Parser MQTTPkt
parsePubREC = do
  _ <- A.word8 0x50
  _ <- parseHdrLen
  PubRECPkt . PubREC <$> aWord16

newtype PubREL = PubREL Word16 deriving(Eq, Show)

instance ByteMe PubREL where
  toByteString (PubREL pid) = BL.singleton 0x62 <> withLength (encodeWord16 pid)

parsePubREL :: A.Parser MQTTPkt
parsePubREL = do
  _ <- A.word8 0x62
  _ <- parseHdrLen
  PubRELPkt . PubREL <$> aWord16

newtype PubCOMP = PubCOMP Word16 deriving(Eq, Show)

instance ByteMe PubCOMP where
  toByteString (PubCOMP pid) = BL.singleton 0x70 <> withLength (encodeWord16 pid)

parsePubCOMP :: A.Parser MQTTPkt
parsePubCOMP = do
  _ <- A.word8 0x70
  _ <- parseHdrLen
  PubCOMPPkt . PubCOMP <$> aWord16

parseSubscribe :: A.Parser MQTTPkt
parseSubscribe = do
  _ <- A.word8 0x82
  hl <- parseHdrLen
  pid <- aWord16
  content <- A.take (fromEnum hl - 2)
  SubscribePkt . SubscribeRequest pid <$> parseSubs content
    where
      parseSubs l = case A.parseOnly (A.many1 parseSub) l of
                      Left x  -> fail x
                      Right x -> pure x
      parseSub = liftA2 (,) aString (wQos <$> A.anyWord8)

data SubscribeResponse = SubscribeResponse Word16 [Maybe QoS] deriving (Eq, Show)

instance ByteMe SubscribeResponse where
  toByteString (SubscribeResponse pid sres) =
    BL.singleton 0x90 <> withLength (encodeWord16 pid <> BL.pack (b <$> sres))

    where
      b Nothing  = 0x80
      b (Just q) = qosW q

parseSubACK :: A.Parser MQTTPkt
parseSubACK = do
  _ <- A.word8 0x90
  hl <- parseHdrLen
  pid <- aWord16
  SubACKPkt . SubscribeResponse pid <$> replicateM (hl-2) (p <$> A.anyWord8)

  where
    p 0x80 = Nothing
    p x    = Just (wQos x)

data UnsubscribeRequest = UnsubscribeRequest Word16 [BL.ByteString]
                        deriving(Eq, Show)

instance ByteMe UnsubscribeRequest where
  toByteString (UnsubscribeRequest pid sreq) =
    BL.singleton 0xa2
    <> withLength (encodeWord16 pid <> mconcat (toByteString <$> sreq))

parseUnsubscribe :: A.Parser MQTTPkt
parseUnsubscribe = do
  _ <- A.word8 0xa2
  hl <- parseHdrLen
  pid <- aWord16
  content <- A.take (fromEnum hl - 2)
  UnsubscribePkt . UnsubscribeRequest pid <$> parseSubs content
    where
      parseSubs l = case A.parseOnly (A.many1 aString) l of
                      Left x  -> fail x
                      Right x -> pure x

newtype UnsubscribeResponse = UnsubscribeResponse Word16 deriving(Eq, Show)

instance ByteMe UnsubscribeResponse where
  toByteString (UnsubscribeResponse pid) = BL.singleton 0xb0 <> withLength (encodeWord16 pid)

parseUnsubACK :: A.Parser MQTTPkt
parseUnsubACK = do
  _ <- A.word8 0xb0
  _ <- parseHdrLen
  UnsubACKPkt . UnsubscribeResponse <$> aWord16
