#!/bin/bash
set -e
swift bundler run
codesign --force --deep --sign - .build/bundler/macEqualizer.app
open .build/bundler/macEqualizer.app
