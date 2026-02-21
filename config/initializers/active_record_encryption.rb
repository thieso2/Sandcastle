# Configure ActiveRecord Encryption from environment variables.
# Keys are generated once per installation by the installer and stored
# in $SANDCASTLE_HOME/.env, ensuring each deployment has unique keys.
if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
  ActiveRecord::Encryption.configure(
    primary_key:         ENV["AR_ENCRYPTION_PRIMARY_KEY"],
    deterministic_key:   ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"],
    key_derivation_salt: ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
  )
end
