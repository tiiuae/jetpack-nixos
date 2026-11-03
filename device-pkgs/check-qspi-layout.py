# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: MIT

import sys
import xml.etree.ElementTree as ET

try:
    layout = ET.parse(sys.argv[1]).getroot()
    devices = layout.findall("device")
    if (
        layout.tag != "partition_layout"
        or not devices
        or any(device.get("type") != "spi" for device in devices)
    ):
        raise ValueError("NVMe recovery flashing requires a QSPI-only firmware layout")
except (ET.ParseError, OSError, ValueError) as error:
    sys.exit(str(error))
