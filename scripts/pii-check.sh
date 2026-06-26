#!/bin/bash
# Comprehensive PII Detection Script
# Run this script in any repository before making it public to check for common PII patterns
# Includes checks for personal information, customer information, and system-specific terms

# Configuration - Add or remove terms that should be checked for
# To add new customers, simply add their names to the CUSTOMER_INFO_TERMS variable
# Separate multiple terms with the | character
# Example: CUSTOMER_INFO_TERMS="customer_name|customer_company|customer_email|Dutchman Manufacturing|Alden Library|Platte Township|New Customer Name"
#
# To add new services, add their key patterns to NETWORK_SERVICE_KEYS
# Example: NETWORK_SERVICE_KEYS="tskey-|AKIA|AIza|ya29|Bearer|Authorization:|ollama|brave|openai"
PERSONAL_ASSISTANT_NAMES="moth|Moth|personal_assistant_name"
SPECIFIC_SYSTEM_NAMES="openclaw|OpenClaw|specific_system_name"
PERSONAL_INFO_TERMS="kkuenzer|administrator|kyle|Kyle"
CUSTOMER_INFO_TERMS="customer_name|customer_company|customer_email|Dutchman Manufacturing|Alden Library|Platte Township"
NETWORK_SERVICE_KEYS="tskey-|AKIA|AIza|ya29|Bearer|Authorization:|ollama|brave|openai|anthropic"

echo "🔍 Comprehensive PII Detection Scan Started"
echo "======================================="

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
echo "👤 Checking for personal assistant and system names..."
grep -r -i "$PERSONAL_ASSISTANT_NAMES\|$SPECIFIC_SYSTEM_NAMES" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "👥 Checking for personal information..."
grep -r -i "$PERSONAL_INFO_TERMS" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "🏢 Checking for customer information..."
grep -r -i "$CUSTOMER_INFO_TERMS" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "🔐 Checking for network service keys..."
grep -r -i "$NETWORK_SERVICE_KEYS" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "🔑 Checking for potential credentials..."
echo "   (This checks for common credential patterns but may produce false positives)"
grep -r -i "password\|passwd\|pwd\|secret\|token\|key.*=.*[a-zA-Z0-9]" . --exclude-dir=.git --exclude-dir=node_modules --exclude="*.svg" --exclude="*.ico" --exclude="*.png" --exclude="*.jpg" --exclude="*.jpeg" --exclude="*.gif" 2>/dev/null

echo ""
echo "📁 Checking for specific paths..."
grep -r "/home/" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null

echo ""
echo "✅ Comprehensive PII Detection Scan Complete"
echo "=========================================="
echo "⚠️  Review the output above for any potential PII that should be removed"
echo "💡 Remember to also check .git history for sensitive information"
echo "📝 Update the configuration variables at the top of this script for your specific terms to check"echo "🔐 Remember to check for network service keys like Tailscale auth keys, AWS keys, etc."
