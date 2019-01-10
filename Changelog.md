# Changelog for net-mqtt

## 0.2.1.0

No externally visible changes, but a few bug fixes I found when
writing an application that published in QoS < 2.  QoS 0 would likely
not transmit (which is probably fine according to the spec, but not
very desirable) and QoS1 didn't check its ACKs, so it would continue
to retry after the server ACKd the message.

## 0.2.0.0

### API Change

Subscriber callbacks now include the MQTT client as the first
argument.  This breaks a circular dependency that prevented callbacks
from being able to publish messages easily.

### Other

Updated to stackage LTS 13.2

