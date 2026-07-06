# XBRL taxonomy smoke corpus

This directory is intentionally only the harness.  The SEC and FASB taxonomy
payloads are downloaded locally and ignored by git because the packages are
large and change over time.

Populate the local URI cache:

```sh
script/fetch-xbrl-taxonomies.sh
```

Run `XsdToHaskell` over every cached XSD:

```sh
script/run-xbrl-xsdtohaskell.sh
```

Useful knobs:

```sh
XBRL_LIMIT=20 script/run-xbrl-xsdtohaskell.sh
XBRL_PATTERN='*/dei/2026/*.xsd' script/run-xbrl-xsdtohaskell.sh
XBRL_FILE_LIST=tests/xbrl-taxonomies/entrypoints-current.txt script/run-xbrl-xsdtohaskell.sh
XBRL_TIMEOUT=120 script/run-xbrl-xsdtohaskell.sh
```

The cache mirrors public schema URLs under `cache/https/...`.  For example,
`https://xbrl.sec.gov/dei/2026/dei-2026.xsd` is cached as
`cache/https/xbrl.sec.gov/dei/2026/dei-2026.xsd`.  `XsdToHaskell` uses this
layout when resolving imported schemas from cached XBRL files.
