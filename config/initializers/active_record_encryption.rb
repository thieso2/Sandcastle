Rails.application.config.after_initialize do
  ActiveRecord::Encryption.configure(
    primary_key: ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY") { Rails.application.secret_key_base[0..31] },
    deterministic_key: ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY") { Rails.application.secret_key_base[32..63] },
    key_derivation_salt: ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT") { Rails.application.secret_key_base[64..95] }
  )
end
