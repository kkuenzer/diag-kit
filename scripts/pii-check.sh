#!/bin/bash
# PII Detection Script
# Run this script in any repository before making it public to check for common PII patterns

echo "🔍 PII Detection Scan Started"
echo "============================"

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo "⚠️  Not in a git repository. Some checks may be limited."
fi

echo ""
echo "📧 Checking for email addresses..."
grep -r "@" . --exclude-dir=.git --exclude-dir=node_modules --exclude="*.svg" --exclude="*.ico" --exclude="*.png" --exclude="*.jpg" --exclude="*.jpeg" --exclude="*.gif" 2>/dev/null | grep -v "://"

echo ""
echo "🌐 Checking for IP addresses..."
grep -r -E "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)" . --exclude-dir=.git --exclude-dir=node_modules --exclude="*.svg" --exclude="*.ico" --exclude="*.png" --exclude="*.jpg" --exclude="*.jpeg" --exclude="*.gif" 2>/dev/null | grep -v "127.0.0.1\|192.168.\|10.\|172.(1[6-9]|2[0-9]|3[01]).\|0.0.0.0\|255.255.255.255"

echo ""
echo "👤 Checking for common personal information..."
grep -r -i "moth\|openclaw\|kkuenzer\|administrator\|kyle" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "🔑 Checking for potential credentials..."
grep -r -i "password\|passwd\|pwd\|secret\|token\|key.*=.*[a-zA-Z0-9]" . --exclude-dir=.git --exclude-dir=node_modules --exclude="*.svg" --exclude="*.ico" --exclude="*.png" --exclude="*.jpg" --exclude="*.jpeg" --exclude="*.gif" 2>/dev/null

echo ""
echo "📁 Checking for specific paths..."
grep -r "/home/" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "✅ PII Detection Scan Complete"
echo "=============================="
echo "⚠️  Review the output above for any potential PII that should be removed"
echo "💡 Remember to also check .git history for sensitive information"