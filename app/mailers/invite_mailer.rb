class InviteMailer < ApplicationMailer
  def invite(user)
    @user = user
    mail subject: "You've been invited to Sandcastle", to: user.email_address
  end
end
