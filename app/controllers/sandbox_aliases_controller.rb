class SandboxAliasesController < ApplicationController
  before_action :set_sandbox

  def create
    a = @sandbox.aliases.build(
      kind: params.dig(:sandbox_alias, :kind).presence,
      value: params.dig(:sandbox_alias, :value).presence&.strip
    )
    if a.save
      DnsManager.publish_best_effort(@sandbox.user)
      SandboxCertificateRefreshJob.perform_later(@sandbox.id) if defined?(SandboxCertificateRefreshJob)
      SandboxCaddyReloadJob.perform_later(@sandbox.id) if defined?(SandboxCaddyReloadJob)
      redirect_to sandbox_path(@sandbox), notice: "Alias added."
    else
      redirect_to sandbox_path(@sandbox), alert: a.errors.full_messages.to_sentence
    end
  end

  def destroy
    a = @sandbox.aliases.find(params[:id])
    a.destroy!
    DnsManager.publish_best_effort(@sandbox.user)
    SandboxCertificateRefreshJob.perform_later(@sandbox.id) if defined?(SandboxCertificateRefreshJob)
    SandboxCaddyReloadJob.perform_later(@sandbox.id) if defined?(SandboxCaddyReloadJob)
    redirect_to sandbox_path(@sandbox), notice: "Alias removed."
  rescue ActiveRecord::RecordNotFound
    redirect_to sandbox_path(@sandbox), alert: "Alias not found."
  end

  private

  def set_sandbox
    @sandbox = policy_scope(Sandbox).find(params[:sandbox_id])
    authorize @sandbox, :show?
  end
end
