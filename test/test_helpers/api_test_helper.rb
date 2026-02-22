# frozen_string_literal: true

module ApiTestHelper
  # Raw tokens matching the api_tokens.yml fixture digests.
  # Format: sc_{prefix_hex}_{48-char secret}
  ALICE_TOKEN = "sc_testaaaa_#{"a" * 48}"
  BOB_TOKEN   = "sc_testbbbb_#{"b" * 48}"

  def auth_headers(raw_token = ALICE_TOKEN)
    { "Authorization" => "Bearer #{raw_token}" }
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include ApiTestHelper
end
