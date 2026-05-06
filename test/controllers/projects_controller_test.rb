require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @other_user = users(:two)
    @project = projects(:alice_web)
    @other_project = projects(:bob_api)
    sign_in_as(@user)
  end

  test "GET edit renders for owner" do
    get edit_project_path(@project)
    assert_response :success
  end

  test "GET edit returns 404 for another user's project" do
    get edit_project_path(@other_project)
    assert_response :not_found
  end

  test "PATCH update saves changes and redirects to settings projects tab" do
    patch project_path(@project), params: {
      project: { name: @project.name, path: "projects/renamed", image: @project.image,
                 vnc_geometry: @project.vnc_geometry, vnc_depth: @project.vnc_depth }
    }
    assert_redirected_to settings_path(anchor: "projects")
    assert_equal "projects/renamed", @project.reload.path
  end

  test "PATCH update re-renders edit on invalid params" do
    patch project_path(@project), params: {
      project: { name: @project.name, path: "/absolute/no", image: @project.image,
                 vnc_geometry: @project.vnc_geometry, vnc_depth: @project.vnc_depth }
    }
    assert_response :unprocessable_entity
    assert_match(/must be relative/, flash[:alert].to_s)
  end

  test "PATCH update returns 404 for another user's project" do
    patch project_path(@other_project), params: { project: { path: "x" } }
    assert_response :not_found
  end

  test "DELETE destroy removes the project and redirects to settings projects tab" do
    assert_difference -> { Project.count }, -1 do
      delete project_path(@project)
    end
    assert_redirected_to settings_path(anchor: "projects")
  end

  test "DELETE destroy returns 404 for another user's project" do
    delete project_path(@other_project)
    assert_response :not_found
  end
end
