class InviteMailer < ApplicationMailer
  def invite(invite)
    @invite = invite
    mail subject: "You've been invited to Sandcastle", to: invite.email
  end
end
