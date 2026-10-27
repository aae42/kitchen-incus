describe file('/etc/kitchen-incus') do
  it { should exist }
  its('mode') { should cmp '0644' }
  its('content') { should match(/converged by Cinc/) }
end

describe directory('/opt/cinc') do
  it { should exist }
end
