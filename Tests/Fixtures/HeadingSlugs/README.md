# GitHub heading anchor fixtures

`Upstream_Fixtures.json` is the unmodified test data from the [github-slugger
2.0.0 source commit](https://github.com/Flet/github-slugger/blob/3461c4350868329c8530904d170358bca1d31448/test/fixtures.json).
The upstream ISC license is included alongside it. These fixtures check the
published slug behavior using plain heading text, independently of the local
Markdown parser.

Regenerate the Swift scalar table from the pinned npm package:

```sh
mkdir -p .build/slugger-vendor/npm
npm pack --ignore-scripts github-slugger@2.0.0 --pack-destination .build/slugger-vendor
tar -xzf .build/slugger-vendor/github-slugger-2.0.0.tgz -C .build/slugger-vendor/npm
node Tests/Fixtures/HeadingSlugs/Generate.mjs .build/slugger-vendor/npm/package Sources/GlancemarkCore/GitHubHeadingScalars.swift
```

npm package integrity: `sha512-IaOQ9puYtjrkq7Y0Ygl9KDZnrf/aiUJYUpVf89y8kyaxbRG7Y1SrX/jaumrv81vc61+kiMempujsM3Yw7w5qcw==`.
