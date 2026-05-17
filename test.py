import urllib.request
import json
url = "https://api.github.com/repos/qdm12/gluetun/issues/3279/comments"
try:
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode('utf-8'))
        for comment in data:
            print(comment['body'])
            print("---")
except Exception as e:
    print(e)
