# Changelog for net-mqtt

## 0.2.0.0

### API Change

Subscriber callbacks now include the MQTT client as the first
argument.  This breaks a circular dependency that prevented callbacks
from being able to publish messages easily.

### Other

Updated to stackage LTS 13.2

