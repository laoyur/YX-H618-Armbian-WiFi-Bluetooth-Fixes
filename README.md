# YX-H618-Armbian-WiFi-Bluetooth-Fixes

Note: This code was summarized from an actual fixing process but has not been tested in a clean build; please use it with caution.

Tested device: TV Box, YX-H618 V11 4GB Ram + 32GB Storage (Officially shipped with Android)
Tested Armbian build: https://github.com/ophub/amlogic-s9xxx-armbian Armbian 26.5.1/6.18.32-ophub/Vontar

Usage:
1. install a Vontar build(like Armbian_26.11.0_allwinner_vontar-h618_resolute_6.18.48_server_2026.09.01.img.gz) from https://github.com/ophub/amlogic-s9xxx-armbian/releases
2. ssh into your system and run `sudo bash install-yx-h618-aic8801.sh`
3. `sudo reboot` if step 2 has run successfully
4. your WiFi and BT should be running correctly
