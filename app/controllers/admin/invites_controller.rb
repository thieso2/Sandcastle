module Admin
  class InvitesController < BaseController
    before_action :set_invite, only: [ :destroy ]

    def index
      authorize Invite
      @invites = Invite.includes(:invited_by).order(created_at: :desc)
    end

    def create
      authorize Invite
      @invite = Invite.new(invite_params.merge(invited_by: Current.user))

      if @invite.save
        InviteMailer.invite(@invite).deliver_later
        redirect_to admin_invites_path, notice: "Invite sent to #{@invite.email}."
      else
        redirect_to admin_invites_path, alert: "Could not send invite: #{@invite.errors.full_messages.join(', ')}"
      end
    end

    def destroy
      authorize @invite
      if @invite.pending?
        @invite.destroy!
        redirect_to admin_invites_path, notice: "Invite revoked."
      else
        redirect_to admin_invites_path, alert: "Only pending invites can be revoked."
      end
    end

    private

    def set_invite
      @invite = Invite.find(params[:id])
    end

    def invite_params
      params.expect(invite: [ :email, :message ])
    end
  end
end
