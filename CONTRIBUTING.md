# Contributing to FastShot

Contributions are welcome. Bug reports, focused feature proposals, documentation improvements, tests, and code changes all help make FastShot better.

## Before you start

- Search existing issues and pull requests before opening a new one.
- Open an issue before investing in a large feature or architectural change so the direction can be discussed first.
- Keep pull requests focused on one problem and explain the user-facing reason for the change.
- Never include private screenshots, credentials, signing identities, or personal data.

## Development setup

FastShot requires macOS 14 or later and Xcode with Swift 6.2 or later.

```sh
swift build
swift test
```

To build the app bundle:

```sh
xcodebuild -project FastShot.xcodeproj -scheme FastShot -configuration Debug \
  -derivedDataPath .build-xcode CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
```

Tests use synthetic images and do not need screen-recording permission.

## Pull requests

1. Create a branch from the current default branch.
2. Follow the existing Swift and SwiftUI conventions in the surrounding code.
3. Add or update tests for behavior changes.
4. Run `swift test` and include the result in the pull-request description.
5. Describe any macOS permission or manual testing needed to verify the change.

By submitting a contribution, you confirm that you have the right to submit it and agree that it is licensed under the repository's [GNU Affero General Public License v3.0 or later](LICENSE).
