require "shellwords"

class GcpOidcSetup
  CREDENTIALS_PATH = "/etc/sandcastle/gcp-credentials.json".freeze
  EXECUTABLE_CACHE_PATH = "/run/sandcastle/oidc/gcp-executable-cache.json".freeze
  TOKEN_URL = "https://sts.googleapis.com/v1/token".freeze
  SUBJECT_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:jwt".freeze

  ATTRIBUTE_MAPPING = {
    "google.subject" => "assertion.sub",
    "attribute.user" => "assertion.user",
    "attribute.sandbox" => "assertion.sandbox",
    "attribute.sandbox_id" => "string(assertion.sandbox_id)"
  }.freeze

  attr_reader :user, :sandbox, :config

  def initialize(user:, sandbox: nil, config: nil)
    @user = user
    @sandbox = sandbox
    @config = config || sandbox&.gcp_oidc_config
  end

  def configured?
    missing_fields.empty?
  end

  def sandbox_configured?
    sandbox.present? && sandbox.gcp_oidc_configured?
  end

  def location
    config&.workload_identity_location.presence || "global"
  end

  def provider_resource
    return nil unless config&.project_number.present? &&
      config.workload_identity_pool_id.present? &&
      config.workload_identity_provider_id.present?

    "projects/#{config.project_number}/locations/#{location}/workloadIdentityPools/#{config.workload_identity_pool_id}/providers/#{config.workload_identity_provider_id}"
  end

  def audience
    provider_resource.present? ? "//iam.googleapis.com/#{provider_resource}" : nil
  end

  def issuer
    @issuer ||= OidcSigner.issuer
  rescue OidcSigner::Error
    nil
  end

  def principal_scope
    sandbox&.gcp_principal_scope.presence || "user"
  end

  def principal
    return nil unless config&.project_number.present? && config.workload_identity_pool_id.present?

    attribute, value = principal_attribute_and_value
    return nil if value.blank?

    "principalSet://iam.googleapis.com/projects/#{config.project_number}/locations/#{location}/workloadIdentityPools/#{config.workload_identity_pool_id}/attribute.#{attribute}/#{value}"
  end

  def credential_config
    return {} unless audience.present?

    config = {
      type: "external_account",
      audience: audience,
      subject_token_type: SUBJECT_TOKEN_TYPE,
      token_url: TOKEN_URL,
      credential_source: {
        executable: {
          command: "/usr/local/bin/sandcastle-oidc gcp executable --audience=#{shell_escape(audience)}",
          timeout_millis: 30000,
          output_file: EXECUTABLE_CACHE_PATH
        }
      }
    }

    if service_account_email.present?
      config[:service_account_impersonation_url] =
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/#{service_account_email}:generateAccessToken"
    end

    config
  end

  def credential_config_json
    JSON.pretty_generate(credential_config)
  end

  def commands
    command_hash = {
      enable_apis: enable_apis_command,
      create_default_service_account: create_default_service_account_command,
      grant_default_roles: default_role_binding_commands,
      create_pool: create_pool_command,
      create_provider: create_provider_command,
      bind_service_account: bind_service_account_command,
      grant_roles: role_binding_commands,
      create_credential_config: create_credential_config_command
    }
    command_hash.compact
  end

  def shell_script
    [
      enable_apis_command,
      create_default_service_account_command,
      *default_role_binding_commands,
      create_pool_command,
      create_provider_command,
      bind_service_account_command,
      *role_binding_commands
    ].compact.join("\n")
  end

  def environment
    return {} unless sandbox_configured?

    {
      "GOOGLE_APPLICATION_CREDENTIALS" => CREDENTIALS_PATH,
      "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" => CREDENTIALS_PATH,
      "GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES" => "1",
      "CLOUDSDK_CORE_PROJECT" => config&.project_id.presence,
      "GOOGLE_CLOUD_PROJECT" => config&.project_id.presence
    }.compact
  end

  def missing_fields
    fields = []
    fields << "SANDCASTLE_HOST" if issuer.blank?
    fields << "gcp_oidc_config" if config.blank?
    fields << "gcp_project_number" if config.present? && config.project_number.blank?
    fields << "gcp_workload_identity_pool_id" if config.present? && config.workload_identity_pool_id.blank?
    fields << "gcp_workload_identity_provider_id" if config.present? && config.workload_identity_provider_id.blank?
    fields << "gcp_default_service_account_email" if sandbox.present? && sandbox.gcp_oidc_enabled? && service_account_email.blank?
    fields
  end

  def as_json(*)
    {
      configured: configured?,
      sandbox_configured: sandbox_configured?,
      missing: missing_fields,
      issuer: issuer,
      config_id: config&.id,
      config_name: config&.name,
      project_id: config&.project_id,
      project_number: config&.project_number,
      default_service_account_email: config&.default_service_account_email,
      default_read_only_roles: GcpOidcConfig::DEFAULT_READ_ONLY_ROLES,
      location: location,
      pool_id: config&.workload_identity_pool_id,
      provider_id: config&.workload_identity_provider_id,
      provider_resource: provider_resource,
      audience: audience,
      attribute_mapping: ATTRIBUTE_MAPPING,
      attribute_mapping_arg: attribute_mapping_arg,
      principal_scope: principal_scope,
      principal: principal,
      service_account_email: service_account_email,
      service_account_source: service_account_source,
      roles: role_list,
      commands: commands,
      shell: shell_script,
      credential_config: credential_config,
      environment: environment
    }
  end

  private

  def principal_attribute_and_value
    if principal_scope == "user"
      [ "user", user.name ]
    else
      [ "sandbox_id", sandbox&.id ]
    end
  end

  def project_selector
    config&.project_selector
  end

  def service_account_email
    sandbox&.effective_gcp_service_account_email.to_s.strip.presence || config&.default_service_account_email
  end

  def service_account_source
    return nil if service_account_email.blank?
    return "sandbox" if sandbox&.gcp_service_account_email.present?

    "default"
  end

  def role_list
    sandbox&.gcp_roles_list || []
  end

  def attribute_mapping_arg
    ATTRIBUTE_MAPPING.map { |key, value| "#{key}=#{value}" }.join(",")
  end

  def enable_apis_command
    return nil unless project_selector.present?

    "gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project=#{shell_escape(project_selector)}"
  end

  def create_pool_command
    return nil unless project_selector.present? && config&.workload_identity_pool_id.present?

    "gcloud iam workload-identity-pools create #{shell_escape(config.workload_identity_pool_id)} " \
      "--project=#{shell_escape(project_selector)} " \
      "--location=#{shell_escape(location)} " \
      "--display-name=#{shell_escape('Sandcastle')}"
  end

  def create_provider_command
    return nil unless project_selector.present? && config&.workload_identity_pool_id.present? &&
      config.workload_identity_provider_id.present? && issuer.present? && audience.present?

    "gcloud iam workload-identity-pools providers create-oidc #{shell_escape(config.workload_identity_provider_id)} " \
      "--project=#{shell_escape(project_selector)} " \
      "--location=#{shell_escape(location)} " \
      "--workload-identity-pool=#{shell_escape(config.workload_identity_pool_id)} " \
      "--issuer-uri=#{shell_escape(issuer)} " \
      "--allowed-audiences=#{shell_escape(audience)} " \
      "--attribute-mapping=#{shell_escape(attribute_mapping_arg)}"
  end

  def create_default_service_account_command
    return nil unless project_selector.present? && config&.default_service_account_email.present?

    "gcloud iam service-accounts describe #{shell_escape(config.default_service_account_email)} " \
      "--project=#{shell_escape(project_selector)} >/dev/null 2>&1 || " \
      "gcloud iam service-accounts create #{shell_escape(config.default_service_account_id)} " \
      "--project=#{shell_escape(project_selector)} " \
      "--display-name=#{shell_escape('Sandcastle read-only')}"
  end

  def default_role_binding_commands
    return [] unless project_selector.present? && config&.default_service_account_email.present?

    GcpOidcConfig::DEFAULT_READ_ONLY_ROLES.map do |role|
      "gcloud projects add-iam-policy-binding #{shell_escape(project_selector)} " \
        "--member=#{shell_escape("serviceAccount:#{config.default_service_account_email}")} " \
        "--role=#{shell_escape(role)}"
    end
  end

  def bind_service_account_command
    return nil unless service_account_email.present? && principal.present? && project_selector.present?

    "gcloud iam service-accounts add-iam-policy-binding #{shell_escape(service_account_email)} " \
      "--project=#{shell_escape(project_selector)} " \
      "--role=roles/iam.workloadIdentityUser " \
      "--member=#{shell_escape(principal)}"
  end

  def role_binding_commands
    return [] unless project_selector.present? && service_account_email.present?

    role_list.map do |role|
      "gcloud projects add-iam-policy-binding #{shell_escape(project_selector)} " \
        "--member=#{shell_escape("serviceAccount:#{service_account_email}")} " \
        "--role=#{shell_escape(role)}"
    end
  end

  def create_credential_config_command
    return nil unless provider_resource.present? && service_account_email.present?

    "gcloud iam workload-identity-pools create-cred-config #{shell_escape(provider_resource)} " \
      "--service-account=#{shell_escape(service_account_email)} " \
      "--executable-command=#{shell_escape("/usr/local/bin/sandcastle-oidc gcp executable --audience=#{audience}")} " \
      "--executable-output-file=#{shell_escape(EXECUTABLE_CACHE_PATH)} " \
      "--output-file=#{shell_escape(CREDENTIALS_PATH)}"
  end

  def shell_escape(value)
    Shellwords.escape(value.to_s)
  end
end
