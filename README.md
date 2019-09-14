# mqtt

An [MQTT][mqtt] protocol implementation for Haskell.

## Client Examples

### Publish

```haskell
main :: IO
main = do
  mc <- runClient mqttConfig{}
  publish mc "tmp/topic" "hello!" False
```

### Subscribe

```haskell
main :: IO
main = do
  mc <- runClient mqttConfig{_msgCB=Just msgReceived}
  print =<< subscribe mc [("tmp/topic1", subOptions), ("tmp/topic2", subOptions)] []
  print =<< waitForClient mc   -- wait for the the client to disconnect

  where
    msgReceived _ t m p = print (t,m,p)
```

[mqtt]: http://mqtt.org/
