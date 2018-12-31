{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Types where

import           Control.Applicative             ((<|>))
import qualified Data.Attoparsec.ByteString.Lazy as A
import           Data.Bits                       (Bits (..), shiftL, testBit,
                                                  (.&.), (.|.))
import qualified Data.ByteString.Lazy            as BL
import           Data.Maybe                      (isJust)
import           Data.Word                       (Word16, Word8)

(≫) :: Bits a => a -> Int -> a
(≫) = shiftR

(≪) :: Bits a => a -> Int -> a
(≪) = shiftL

class ByteMe a where
  toBytes :: a -> [Word8]
  toBytes = BL.unpack . toByteString
  toByteString :: a -> BL.ByteString
  toByteString = BL.pack . toBytes

data ControlPktType = Connect
                    | ConnACK
                    | Publish Bool Word8 Bool -- Dup, QoS, Retain
                    | PubACK
                    | PubRec
                    | PubRel
                    | PubComp
                    | Subscribe
                    | SubACK
                    | Unsubscribe
                    | UnsubACK
                    | PingReq
                    | PingRes
                    | Disconnect deriving(Show, Eq)

boolBit :: Bool -> Word8
boolBit False = 0
boolBit True  = 1

instance ByteMe ControlPktType where
  toByteString = BL.singleton . b

    where
      b Connect = 0x10
      b ConnACK = 0x20
      b (Publish d q r) = 0x30 .|. f
        where f = (db ≪ 3) .|. (qb ≪ 1) .|. rb
              db = boolBit d
              qb = q .&. 0x3
              rb = boolBit r
      b PubACK = 0x40
      b PubRec = 0x50
      b PubRel = 0x62
      b PubComp = 0x70
      b Subscribe = 0x82
      b SubACK = 0x90
      b Unsubscribe = 0xa2
      b UnsubACK = 0xb0
      b PingReq = 0xc0
      b PingRes = 0xd0
      b Disconnect = 0xe0

parseControlPktType :: A.Parser ControlPktType
parseControlPktType = Connect <$ A.word8 0x10
                      <|> ConnACK <$ A.word8 0x20
                      <|> parsePublish
                      <|> PubACK <$ A.word8 0x40
                      <|> PubRec <$ A.word8 0x50
                      <|> PubRel <$ A.word8 0x62
                      <|> PubComp <$ A.word8 0x70
                      <|> Subscribe <$ A.word8 0x82
                      <|> SubACK <$ A.word8 0x90
                      <|> Unsubscribe <$ A.word8 0xa2
                      <|> UnsubACK <$ A.word8 0xb0
                      <|> PingReq <$ A.word8 0xc0
                      <|> PingRes <$ A.word8 0xd0
                      <|> Disconnect <$ A.word8 0xe0
  where
    parsePublish = do
      w <- A.satisfy (\x -> x .&. 0xf0 == 0x30)
      let d = w .&. 0x8 == 0x8
          q = (w ≫ 1) .&. 3
          r = w .&. 1 == 1
      pure $ Publish d q r

parseHdrLen :: A.Parser Int
parseHdrLen = go 0 1
  where
    go :: Int -> Int -> A.Parser Int
    go v m = do
      x <- A.anyWord8
      let a = fromEnum (x .&. 127) * m + v
      if x .&. 128 /= 0
        then go a (m*128)
        else pure a

encodeLength :: Int -> [Word8]
encodeLength n = go (n `quotRem` 128)
  where
    go (x,e)
      | x > 0 = en (e .|. 128) : go (x `quotRem` 128)
      | otherwise = [en e]

    en :: Int -> Word8
    en = toEnum

decodeLength :: [Word8] -> Int
decodeLength = go 0 1
  where
    go v _ [] = v
    go v m (x:xs)
      | x .&. 128 /= 0 = go a (m*128) xs
      | otherwise = a

      where a = d (x .&. 127) * m + v

    d :: Word8 -> Int
    d = fromEnum

encodeWord16 :: Word16 -> BL.ByteString
encodeWord16 a = let (h,l) = a `quotRem` 256 in BL.pack [w h, w l]
    where w = toEnum.fromEnum

instance ByteMe BL.ByteString where
  toByteString a = (encodeWord16 . toEnum . fromEnum . BL.length) a <> a

data ProtocolLevel = Protocol311 deriving(Eq, Show)

instance ByteMe ProtocolLevel where toByteString _ = BL.singleton 4

data LastWill = LastWill {
  _willRetain  :: Bool
  , _willQoS   :: Word8
  , _willTopic :: BL.ByteString
  , _willMsg   :: BL.ByteString
  } deriving(Eq, Show)

data ConnectFlags = ConnectFlags {
  _username       :: Maybe BL.ByteString
  , _password     :: Maybe BL.ByteString
  , _lastWill     :: Maybe LastWill
  , _cleanSession :: Bool
  , _keepAlive    :: Word16
  , _connID       :: BL.ByteString
  } deriving (Eq, Show)

instance ByteMe ConnectFlags where
  toByteString ConnectFlags{..} = BL.singleton connBits
                                  <> encodeWord16 _keepAlive
                                  <> toByteString _connID
                                  <> lwt _lastWill
                                  <> perhaps _username
                                  <> perhaps _password
    where connBits = hasu .|. hasp .|. willBits .|. clean
            where
              hasu = (boolBit $ isJust _username) ≪ 7
              hasp = (boolBit $ isJust _password) ≪ 6
              clean = boolBit _cleanSession ≪ 1
              willBits = case _lastWill of
                           Nothing -> 0
                           Just LastWill{..} -> 4 .|. ((_willQoS .&. 0x3) ≪ 4) .|. (boolBit _willRetain ≪ 5)

          lwt :: Maybe LastWill -> BL.ByteString
          lwt Nothing = mempty
          lwt (Just LastWill{..}) = toByteString _willTopic <> toByteString _willMsg

          perhaps :: Maybe BL.ByteString -> BL.ByteString
          perhaps Nothing  = ""
          perhaps (Just s) = toByteString s

data MQTTFragment = StringPkt BL.ByteString
                  | PLevelPkt ProtocolLevel
                  | ConnFlagsPkt ConnectFlags
                  | ConnACKFlagsPkt ConnACKFlags
                  | Int16Pkt Word16
                  | Word8Pkt Word8
                  deriving (Eq, Show)

instance ByteMe MQTTFragment where
  toByteString (StringPkt x)       = toByteString x
  toByteString (ConnFlagsPkt x)    = toByteString x
  toByteString (ConnACKFlagsPkt x) = toByteString x
  toByteString (Int16Pkt x)        = encodeWord16 x
  toByteString (Word8Pkt x)        = BL.singleton x
  toByteString (PLevelPkt x)       = toByteString x

data MQTTPkt = MQTTPkt ControlPktType [MQTTFragment] deriving (Eq, Show)

instance ByteMe MQTTPkt where
  toByteString (MQTTPkt cp x) = toByteString cp <> ln <> rest
    where rest = mconcat $ toByteString <$> x
          ln = BL.pack $ encodeLength (fromEnum $ BL.length rest)


parsePacket :: A.Parser MQTTPkt
parsePacket = parseConnect <|> parseConnectACK

aWord16 :: A.Parser Word16
aWord16 = A.anyWord8 >>= \h -> A.anyWord8 >>= \l -> pure $ (c h ≪ 8) .|. c l
  where c = toEnum . fromEnum

aString :: A.Parser BL.ByteString
aString = do
  n <- aWord16
  s <- A.take (fromEnum n)
  pure $ BL.fromStrict s

parseConnect :: A.Parser MQTTPkt
parseConnect = do
  _ <- A.word8 0x10
  _ <- parseHdrLen
  _ <- A.string "\NUL\EOTMQTT\EOT" -- "MQTT" Protocol level = 4
  connFlagBits <- A.anyWord8
  keepAlive <- aWord16
  cid <- aString
  lwt <- parseLwt connFlagBits
  u <- mstr (testBit connFlagBits 7)
  p <- mstr (testBit connFlagBits 6)
  pure $ MQTTPkt Connect [StringPkt "MQTT", PLevelPkt Protocol311,
                          ConnFlagsPkt ConnectFlags{_connID=cid, _username=u, _password=p,
                                                    _lastWill=lwt, _keepAlive=keepAlive,
                                                    _cleanSession=testBit connFlagBits 1}]

  where
    mstr :: Bool -> A.Parser (Maybe BL.ByteString)
    mstr False = pure Nothing
    mstr True  = Just <$> aString

    parseLwt bits
      | testBit bits 2 = do
          top <- aString
          msg <- aString
          pure $ Just LastWill{_willTopic=top, _willMsg=msg,
                               _willRetain=testBit bits 5,
                               _willQoS=(bits ≫ 3) .&. 0x3}
      | otherwise = pure Nothing

data ConnACKFlags = ConnACKFlags Bool Word8 deriving (Eq, Show)

instance ByteMe ConnACKFlags where
  toBytes (ConnACKFlags sp rc) = [boolBit sp, rc]

parseConnectACK :: A.Parser MQTTPkt
parseConnectACK = do
  _ <- A.word8 0x20
  _ <- A.word8 2 -- two bytes left
  ackFlags <- A.anyWord8
  rc <- A.anyWord8
  pure $ MQTTPkt ConnACK [ConnACKFlagsPkt $ ConnACKFlags (testBit ackFlags 0) rc]

