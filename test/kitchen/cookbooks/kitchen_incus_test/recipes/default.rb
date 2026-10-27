file '/etc/kitchen-incus' do
  content "converged by #{ChefUtils::Dist::Infra::PRODUCT}\n"
  mode '0644'
end
