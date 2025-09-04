# Security Guidelines

## Important Security Notice

This repository contains a Binance API client library. To protect your trading accounts and API credentials, please follow these security guidelines carefully.

## Sensitive Files (Never Commit These)

The following files contain sensitive information and should **NEVER** be committed to version control:

- `config.toml` - Contains your API keys and secrets
- `key/` directory - Contains private key files
- `test.jl` - May contain test data with real credentials
- `Strategy.jl` - May contain proprietary trading strategies
- `Manifest.toml` - Contains exact dependency versions (may reveal environment details)

These files are already included in `.gitignore` to prevent accidental commits.

## Setting Up Your Configuration

1. **Copy the example configuration:**
   ```bash
   cp config_example.toml config.toml
   ```

2. **Generate ED25519 keys (if using ED25519 signature method):**
   ```bash
   mkdir -p key
   openssl genpkey -algorithm Ed25519 -out key/ed25519-private.pem
   openssl pkey -in key/ed25519-private.pem -pubout -out key/ed25519-public.pem
   ```

3. **Edit `config.toml` with your actual credentials:**
   - Replace `YOUR_API_KEY_HERE` with your Binance API key
   - Replace `YOUR_SECRET_KEY_HERE` with your Binance secret key
   - Set appropriate paths for your private keys
   - Configure other settings as needed

## API Key Security Best Practices

1. **Use Binance Testnet for development:**
   - Set `testnet = true` in your config during development
   - Only use mainnet for production trading

2. **Restrict API Key Permissions:**
   - Only enable necessary permissions (e.g., "Enable Reading", "Enable Spot & Margin Trading")
   - Never enable "Enable Withdrawals" unless absolutely necessary
   - Regularly review and rotate your API keys

3. **IP Whitelist:**
   - Configure IP restrictions on your Binance API keys
   - Only allow access from trusted IP addresses

4. **Environment Variables (Alternative):**
   Instead of using `config.toml`, you can set environment variables:
   ```bash
   export BINANCE_API_KEY="your_api_key"
   export BINANCE_SECRET_KEY="your_secret_key"
   ```

## File Permissions

Ensure your configuration and key files have restrictive permissions:

```bash
chmod 600 config.toml
chmod 600 key/ed25519-private.pem
chmod 644 key/ed25519-public.pem
```

## What to Do If Keys Are Compromised

If you accidentally commit sensitive information or suspect your keys are compromised:

1. **Immediately disable the API key** in your Binance account
2. **Generate new API keys** with fresh credentials
3. **Remove sensitive data from git history:**
   ```bash
   # Remove file from all commits (use with caution)
   git filter-branch --force --index-filter 'git rm --cached --ignore-unmatch config.toml' --prune-empty --tag-name-filter cat -- --all
   ```
4. **Force push** to remote repository (if already pushed)

## Development Guidelines

- **Never hardcode credentials** in source code
- **Use the testnet** for all development and testing
- **Test with small amounts** when using mainnet
- **Keep your dependencies updated** for security patches
- **Review code** before committing to ensure no sensitive data is included

## Reporting Security Issues

If you discover a security vulnerability in this library, please report it privately by emailing the maintainer rather than opening a public issue.

## Additional Resources

- [Binance API Security Best Practices](https://binance-docs.github.io/apidocs/spot/en/#general-info)
- [Binance API Key Management](https://www.binance.com/en/support/faq/how-to-create-api-360002502072)
- [OpenSSL Key Generation Guide](https://wiki.openssl.org/index.php/Command_Line_Elliptic_Curve_Operations)