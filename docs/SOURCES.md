# Primary sources and verification notes

Design references checked during the planning conversation on 2026-10-07. These links support platform constraints and source selection; they do not establish implemented behavior, benchmark results, or current vulnerability exposure. Recheck SDK availability, APIs, terms, source cadences, and versions when implementing.

## Apple platform and local inference

- [iPhone Air technical specifications](https://www.apple.com/iphone-air/specs/): A19 Pro, 5-core GPU, 16-core Neural Engine. Hardware alone does not determine a safe model size.
- [Apple's iPhone 17 Pro announcement](https://www.apple.com/newsroom/2025/09/apple-unveils-iphone-17-pro-and-iphone-17-pro-max/): A19 Pro, 6-core GPU, and vapor-chamber cooling. Benchmark the actual app; do not translate GPU core count into an assumed percentage improvement.
- [Finish tasks in the background, WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/): iOS background execution is discretionary; continued user-started processing requires progress and expiration handling, with background GPU support gated by device capabilities.
- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados): implementation reference to recheck against the selected deployment target and SDK.
- [llama.cpp](https://github.com/ggml-org/llama.cpp): embedded C/C++ inference and Apple Metal support.
- [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases): Apple/iOS artifacts; select and pin a verified compatible revision during implementation.
- [MLX Swift examples](https://github.com/ml-explore/mlx-swift-examples): alternate Apple inference path for evaluation, not a second required runtime.
- [SQLite FTS5](https://www.sqlite.org/fts5.html): lexical full-text retrieval. Embedding-based semantic retrieval requires a separate component.

## Vulnerability and remediation evidence

- [Official CVE List](https://github.com/CVEProject/cvelistV5): canonical CVE records, revisions, schema information, and usage terms.
- [NVD vulnerability API](https://nvd.nist.gov/developers/vulnerabilities): enrichment and query API; validate current pagination and modification-window behavior.
- [NVD developer guidance](https://nvd.nist.gov/developers/start-here): verify current source usage and polling guidance before enabling a collector adapter. This planning session did not establish a guaranteed NVD polling entitlement.
- [CISA Known Exploited Vulnerabilities catalog](https://www.cisa.gov/known-exploited-vulnerabilities-catalog): observed exploitation as one prioritization input; absence is not proof of safety.
- [FIRST EPSS](https://www.first.org/epss/): daily probability estimates for exploitation in the next 30 days. Keep dates and distinguish likelihood from CVSS severity and actual exploitation evidence.
- [Microsoft Security Update Guide](https://msrc.microsoft.com/update-guide/en-us/): authoritative Microsoft product/update guidance.
- [AWS security bulletins](https://aws.amazon.com/security/security-bulletins/): AWS advisories and customer actions where applicable.
- [AWS guidance on monitoring security bulletins](https://docs.aws.amazon.com/prescriptive-guidance/latest/vulnerability-management/monitor-aws-security-bulletins.html): source-monitoring context.

Add verified Apple, Red Hat, Ubuntu, and other vendor advisory adapters as supported products expand. Do not fabricate an integration contract from these reference links; inspect each actual API/schema and terms first.
