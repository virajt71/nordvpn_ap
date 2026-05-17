import urllib.request
import re
url = "https://raw.githubusercontent.com/qdm12/gluetun/master/README.md"
req = urllib.request.Request(url)
with urllib.request.urlopen(req) as response:
    content = response.read().decode('utf-8')
    for line in content.split('\n'):
        if 'DNS' in line:
            print(line)
