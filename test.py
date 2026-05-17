import yaml
with open("access_point/AdGuardHome.yaml") as f:
    try:
        data = yaml.safe_load(f)
        print("YAML is valid.")
    except Exception as e:
        print(e)
