class TestMailer < ApplicationMailer
  def test(user)
    mail subject: "Sandcastle SMTP Test", to: user.email_address
  end
end
