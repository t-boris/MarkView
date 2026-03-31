#!/bin/bash
# MarkView — Quick Setup Script
# Run this on your Mac: cd MarkView && chmod +x setup.sh && ./setup.sh

set -e

echo "🔧 MarkView Setup"
echo "=================="

# 1. Check XcodeGen
if ! command -v xcodegen &> /dev/null; then
    echo "❌ XcodeGen not found. Install with: brew install xcodegen"
    exit 1
fi
echo "✅ XcodeGen found"

# 2. Generate Xcode project
echo "📦 Generating Xcode project..."
xcodegen generate
echo "✅ MarkView.xcodeproj created"

# 3. Open in Xcode
echo "🚀 Opening in Xcode..."
open MarkView.xcodeproj

echo ""
echo "=================="
echo "✅ Done! Xcode should be opening now."
echo ""
echo "Next steps:"
echo "  1. Select your development team in Signing & Capabilities"
echo "  2. Press Cmd+R to build and run"
echo "  3. Use File > Open to load a .md file"
echo ""
echo "Test file available at: TestFiles/demo.md"
