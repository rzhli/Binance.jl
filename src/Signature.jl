module Signature

using SHA, Base64, OpenSSL

using ..Config: BinanceConfig

export CryptoSigner, BinanceSigner, HMAC_SHA256, ED25519, RSA,
    HmacSigner, Ed25519Signer, RsaSigner, NoSigner, create_signer, sign_message

const HMAC_SHA256 = "HMAC_SHA256"
const ED25519 = "ED25519"
const RSA = "RSA"

abstract type CryptoSigner end

# HMAC SHA256 Signer (most common)
struct HmacSigner <: CryptoSigner
    secret_key::String
    secret_bytes::Vector{UInt8}
end

HmacSigner(secret_key::String) = HmacSigner(secret_key, Vector{UInt8}(codeunits(secret_key)))

struct NoSigner <: CryptoSigner end

# Ed25519 Signer (using OpenSSL)
struct Ed25519Signer <: CryptoSigner
    private_key_path::String
    private_key_pass::String
    private_key::OpenSSL.EvpPKey
    public_key::Vector{UInt8}

    function Ed25519Signer(private_key_path::String, private_key_pass::String)
        if isempty(private_key_path)
            error("Private key path is required for Ed25519 signature")
        end
        private_key = load_private_key(private_key_path, private_key_pass)

        # Derive public key path from private key path
        public_key_path = replace(private_key_path, "-private.pem" => "-public.pem")
        public_key = if isfile(public_key_path)
            load_ed25519_public_key(public_key_path)
        else
            # Fallback for different naming conventions, e.g. id_ed25519 and id_ed25519.pub
            public_key_path_pub = private_key_path * ".pub"
            if isfile(public_key_path_pub)
                load_ed25519_public_key(public_key_path_pub)
            else
                UInt8[]
            end
        end
        new(private_key_path, private_key_pass, private_key, public_key)
    end
end

# RSA Signer
struct RsaSigner <: CryptoSigner
    private_key_path::String
    private_key::OpenSSL.EvpPKey

    function RsaSigner(private_key_path::String, private_key_pass::String="")
        if isempty(private_key_path)
            error("Private key path is required for RSA signature")
        end
        new(private_key_path, load_private_key(private_key_path, private_key_pass))
    end
end

const BinanceSigner = Union{HmacSigner,Ed25519Signer,RsaSigner,NoSigner}

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
    elseif config.signature_method == RSA
        if isempty(config.private_key_path)
            error("Private key path is required for RSA signature")
        end
        return RsaSigner(config.private_key_path, config.private_key_pass)
    elseif config.signature_method == "NONE"
        return NoSigner()
    else
        error("Unsupported signature method: $(config.signature_method)")
    end
end

# RSA signature implementation
function sign_message(signer::RsaSigner, message::String)
    try
        return base64encode(evp_digest_sign(signer.private_key, Vector{UInt8}(message), OpenSSL.EvpSHA256()))
    catch e
        error("Failed to sign message with RSA private key using OpenSSL. Ensure the key path is correct. Error: $e")
    end
end

# HMAC SHA256 signature implementation
function sign_message(signer::HmacSigner, message::String)
    return bytes2hex(SHA.hmac_sha256(signer.secret_bytes, message))
end

sign_message(::NoSigner, ::String) = throw(ArgumentError(
    "This client has signature_method=NONE and cannot send signed requests",
))

# Ed25519 signature implementation using OpenSSL
function sign_message(signer::Ed25519Signer, message::String)
    try
        return base64encode(evp_digest_sign(signer.private_key, Vector{UInt8}(message), nothing))
    catch e
        error("Failed to sign message with Ed25519 private key using OpenSSL. Ensure the key path and passphrase are correct. Error: $e")
    end
end

function load_private_key(file_path::String, password::String="")
    if !isfile(file_path)
        error("Private key file not found: $file_path")
    end

    pem = read(file_path)
    GC.@preserve pem password begin
        bio = ccall(
            (:BIO_new_mem_buf, OpenSSL.libcrypto),
            Ptr{Cvoid},
            (Ptr{UInt8}, Cint),
            pointer(pem),
            length(pem),
        )
        bio == C_NULL && throw(OpenSSL.OpenSSLError())

        try
            key = ccall(
                (:PEM_read_bio_PrivateKey, OpenSSL.libcrypto),
                Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cstring),
                bio,
                C_NULL,
                C_NULL,
                password,
            )
            key == C_NULL && throw(OpenSSL.OpenSSLError())
            return OpenSSL.EvpPKey(key)
        finally
            ccall((:BIO_free, OpenSSL.libcrypto), Cint, (Ptr{Cvoid},), bio)
        end
    end
end

function evp_digest_sign(private_key::OpenSSL.EvpPKey, message::Vector{UInt8}, digest::Union{OpenSSL.EvpDigest,Nothing})
    ctx = OpenSSL.EvpDigestContext()
    try
        if digest === nothing
            result = ccall(
                (:EVP_DigestSignInit, OpenSSL.libcrypto),
                Cint,
                (OpenSSL.EvpDigestContext, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Ptr{Cvoid}, OpenSSL.EvpPKey),
                ctx,
                C_NULL,
                C_NULL,
                C_NULL,
                private_key,
            )
        else
            result = ccall(
                (:EVP_DigestSignInit, OpenSSL.libcrypto),
                Cint,
                (OpenSSL.EvpDigestContext, Ptr{Ptr{Cvoid}}, OpenSSL.EvpDigest, Ptr{Cvoid}, OpenSSL.EvpPKey),
                ctx,
                C_NULL,
                digest,
                C_NULL,
                private_key,
            )
        end
        result == 1 || throw(OpenSSL.OpenSSLError())

        signature_length = Ref{Csize_t}(0)
        GC.@preserve message signature_length begin
            message_ptr = isempty(message) ? Ptr{UInt8}(C_NULL) : pointer(message)
            result = ccall(
                (:EVP_DigestSign, OpenSSL.libcrypto),
                Cint,
                (OpenSSL.EvpDigestContext, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t),
                ctx,
                C_NULL,
                signature_length,
                message_ptr,
                length(message),
            )
            result == 1 || throw(OpenSSL.OpenSSLError())

            signature = Vector{UInt8}(undef, signature_length[])
            result = ccall(
                (:EVP_DigestSign, OpenSSL.libcrypto),
                Cint,
                (OpenSSL.EvpDigestContext, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t),
                ctx,
                pointer(signature),
                signature_length,
                message_ptr,
                length(message),
            )
            result == 1 || throw(OpenSSL.OpenSSLError())
            resize!(signature, signature_length[])
            return signature
        end
    finally
        finalize(ctx)
    end
end

# HMAC-SHA256 implementation with local buffers (thread-safe)
function hmac_sha256(key::Vector{UInt8}, message::Vector{UInt8})
    return SHA.hmac_sha256(key, message)
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
end # end of module
