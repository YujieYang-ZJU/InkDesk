# Contributing to InkDesk

Issues and pull requests are welcome. Describe the behavior you expected, what
happened, and your macOS or E1001 firmware version. For display issues, state the
device model, power source, and whether the App received a display confirmation.

## Local checks

Run from the repository root on macOS:

```sh
./build.sh --test
codesign --verify --deep --strict InkDesk.app
./ESP-IDF/tests/run_host_tests.sh
```

The App checks use mock AI responses and an isolated local HTTP server; they do
not call a paid AI API or read the production API key. The firmware host checks
require a C compiler with AddressSanitizer/UndefinedBehaviorSanitizer and Python
3.9 or later. Hardware changes also need an ESP-IDF build and an E1001 test;
describe any hardware behavior you could not verify.

Keep changes focused, and explain the resulting behavior and relevant checks in
your pull request. For sync protocol changes, keep the App and firmware in step
and preserve the retry, immutable frame, and duplicate-event behavior.

Do not attach API keys, Wi-Fi passwords, pairing tokens, local project data, or
credential-bearing firmware images to commits, issues, or logs. Use placeholders
in reproducible examples.

By contributing, you agree to distribute your contributions under the project's
[MIT License](LICENSE), while preserving any applicable third-party notices.
