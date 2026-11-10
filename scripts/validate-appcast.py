#!/usr/bin/env python3
"""Refuse to publish a feed that cannot update the bundled release."""
import base64
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

feed, version, public_key = sys.argv[1:]
assert len(base64.b64decode(public_key, validate=True)) == 32, 'Invalid Sparkle public key'
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).findall('./channel/item')
item = next(item for item in items if item.findtext('sparkle:version', namespaces=ns) == version)
enclosure = item.find('enclosure')
assert enclosure is not None, 'Missing download'
assert enclosure.attrib['url'].startswith('https://github.com/'), 'Download must use HTTPS on GitHub'
assert len(base64.b64decode(enclosure.attrib['{' + ns['sparkle'] + '}edSignature'], validate=True)) == 64, 'Missing signature'
archive = Path(feed).parent / f'FastShot-{version}-universal.zip'
assert int(enclosure.attrib['length']) == archive.stat().st_size, 'Archive size mismatch'
print(f'Validated signed appcast for {version}')
