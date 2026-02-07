module Signature

using SHA, Base64, Random

using ..Config: BinanceConfig

export CryptoSigner, HMAC_SHA256, ED25519, RSA, HmacSigner, Ed25519Signer, RsaSigner, sign_message

const HMAC_SHA256 = "HMAC_SHA256"
const ED25519 = "ED25519"
const RSA = "RSA"

abstract type CryptoSigner end

# HMAC SHA256 Signer (most common)
struct HmacSigner <: CryptoSigner
    secret_key::String
end

# Ed25519 Signer (using OpenSSL)
struct Ed25519Signer <: CryptoSigner
    private_key_path::String
    private_key_pass::String
    public_key::Vector{UInt8}

    function Ed25519Signer(private_key_path::String, private_key_pass::String)
        if isempty(private_key_path)
            error("Private key path is required for Ed25519 signature")
        end
        # Derive public key path from private key path
        public_key_path = replace(private_key_path, "-private.pem" => "-public.pem")
        if !isfile(public_key_path)
            # Fallback for different naming conventions, e.g. id_ed25519 and id_ed25519.pub
            public_key_path_pub = private_key_path * ".pub"
            if isfile(public_key_path_pub)
                public_key_path = public_key_path_pub
            else
                error("Could not find public key file. Tried: $public_key_path and $public_key_path_pub")
            end
        end
        public_key = load_ed25519_public_key(public_key_path)
        new(private_key_path, private_key_pass, public_key)
    end
end

# RSA Signer
struct RsaSigner <: CryptoSigner
    private_key_path::String
end

# Create signer based on configuration
function create_signer(config::BinanceConfig)
    if config.signature_method == HMAC_SHA256
        if isempty(config.api_secret)
            error("API secret is required for HMAC signature")
        end
        return HmacSigner(config.api_secret)
    elseif config.signature_method == ED25519
        if isempty(config.private_key_path) 
            error("Private key path is required for Ed25519 signature")
        end
        return Ed25519Signer(config.private_key_path, config.private_key_pass)
    else
        error("Unsupported signature method: $(config.signature_method)")
    end
end

# RSA signature implementation
function sign_message(signer::RsaSigner, message::String)
    try
        # Use openssl to sign and then base64 encode, as shown in Binance docs
        cmd = pipeline(`echo -n $message`, `openssl dgst -sha256 -sign $(signer.private_key_path)`, `openssl enc -base64 -A`)
        signature_b64 = read(cmd, String)
        return strip(signature_b64) # remove any trailing newline
    catch e
        error("Failed to sign message with RSA private key using OpenSSL. Ensure OpenSSL is installed and the key path is correct. Error: $e")
    end
end

# HMAC SHA256 signature implementation
function sign_message(signer::HmacSigner, message::String)
    # Convert secret key and message to bytes
    key_bytes = Vector{UInt8}(signer.secret_key)
    message_bytes = Vector{UInt8}(message)

    # Compute HMAC-SHA256
    signature_bytes = hmac_sha256(key_bytes, message_bytes)

    # Convert to hex string (lowercase)
    return bytes2hex(signature_bytes)
end

# Ed25519 signature implementation using OpenSSL
function sign_message(signer::Ed25519Signer, message::String)
    try
        # Ed25519 is a "pure" signature algorithm, meaning it performs its own hashing internally.
        # Therefore, unlike RSA, we do not specify a separate digest algorithm (e.g., -sha256)
        # when using `openssl dgst`. The signing algorithm is determined from the key type.
        # The command signs the message and then Base64 encodes the raw signature.
        cmd = pipeline(`echo -n $message`, `openssl dgst -sign $(signer.private_key_path) -passin pass:$(signer.private_key_pass)`, `openssl enc -base64 -A`)
        signature_b64 = read(cmd, String)

        return strip(signature_b64)  # Remove any trailing newline
    catch e
        error("Failed to sign message with Ed25519 private key using OpenSSL. Ensure OpenSSL is installed and the key path is correct. Error: $e")
    end
end

# HMAC-SHA256 implementation with local buffers (thread-safe)
function hmac_sha256(key::Vector{UInt8}, message::Vector{UInt8})
    # If key is longer than block size, hash it
    block_size = 64
    actual_key = length(key) > block_size ? sha256(key) : key
    key_len = length(actual_key)

    # Pad key to block size
    padded_key = Vector{UInt8}(undef, block_size)
    @inbounds for i in 1:key_len
        padded_key[i] = actual_key[i]
    end
    @inbounds for i in (key_len+1):block_size
        padded_key[i] = 0x00
    end

    # Compute inner hash: SHA256((key ⊻ 0x36) || message)
    inner_data = Vector{UInt8}(undef, block_size + length(message))
    @inbounds for i in 1:block_size
        inner_data[i] = padded_key[i] ⊻ 0x36
    end
    @inbounds copyto!(inner_data, block_size + 1, message, 1, length(message))
    inner_hash = sha256(inner_data)

    # Compute outer hash: SHA256((key ⊻ 0x5c) || inner_hash)
    outer_data = Vector{UInt8}(undef, block_size + 32)  # SHA256 output is 32 bytes
    @inbounds for i in 1:block_size
        outer_data[i] = padded_key[i] ⊻ 0x5c
    end
    @inbounds copyto!(outer_data, block_size + 1, inner_hash, 1, 32)

    return sha256(outer_data)
end

# Load Ed25519 private key from file
function load_ed25519_private_key(file_path::String, password::String="")
    if !isfile(file_path)
        error("Ed25519 private key file not found: $file_path")
    end

    try
        # Try to extract key using OpenSSL
        if isempty(password)
            # Unencrypted key
            result = read(`openssl pkey -in $file_path -text -noout`, String)
        else
            # Encrypted key
            result = read(pipeline(`echo $password`, `openssl pkey -in $file_path -passin stdin -text -noout`), String)
        end

        # Extract the raw private key bytes from OpenSSL output
        # This is a simplified extraction - in production use proper ASN.1 parsing
        lines = split(result, '\n')
        key_lines = String[]
        in_key_section = false

        for line in lines
            if contains(line, "priv:")
                in_key_section = true
                continue
            elseif in_key_section && contains(line, "pub:")
                break
            elseif in_key_section
                # Extract hex bytes
                hex_matches = collect(eachmatch(r"[0-9a-f]{2}", line))
                if !isempty(hex_matches)
                    push!(key_lines, join([m.match for m in hex_matches], ""))
                end
            end
        end

        if isempty(key_lines)
            error("Could not extract Ed25519 private key from file")
        end

        # Convert hex string to bytes
        hex_string = join(key_lines, "")
        return hex2bytes(hex_string[1:64])  # Ed25519 private key is 32 bytes (64 hex chars)

    catch e
        error("Failed to load Ed25519 private key: $e")
    end
end

# Load Ed25519 public key from file
function load_ed25519_public_key(file_path::String)
    if !isfile(file_path)
        error("Ed25519 public key file not found: $file_path")
    end

    content = read(file_path, String)

    # Check if it's a Binance-generated key format (.pub file with base64 content)
    if endswith(file_path, ".pub")
        # Binance public keys are typically base64 encoded without PEM headers
        content = strip(content)  # Remove whitespace
        try
            return base64decode(content)
        catch e
            error("Failed to decode Binance public key file: $e")
        end
    end

    # Handle PEM format
    if contains(content, "BEGIN PUBLIC KEY")
        start_marker = "-----BEGIN PUBLIC KEY-----"
        end_marker = "-----END PUBLIC KEY-----"

        start_idx = findfirst(start_marker, content)
        end_idx = findfirst(end_marker, content)

        if isnothing(start_idx) || isnothing(end_idx)
            error("Invalid PEM format in file: $file_path")
        end

        # Extract base64 content
        base64_content = content[start_idx[end]+1:end_idx[1]-1]
        base64_content = replace(base64_content, r"\s" => "")  # Remove whitespace

        try
            return base64decode(base64_content)
        catch e
            error("Failed to decode base64 content from public key file: $e")
        end
    end

    error("Unsupported public key format in file: $file_path")
end

# Utility function to convert hex string to bytes (pre-allocated)
function hex2bytes(hex_str::String)
    len = length(hex_str)
    if len % 2 != 0
        error("Hex string must have even length")
    end

    result = Vector{UInt8}(undef, len ÷ 2)
    @inbounds for i in 1:(len÷2)
        idx = 2i - 1
        result[i] = parse(UInt8, SubString(hex_str, idx, idx + 1), base=16)
    end

    return result
end
end # end of module
