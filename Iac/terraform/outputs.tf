# Cloned instances outputs
output "cloned_instance_ids" {
  description = "The IDs of the cloned instances."
  value       = module.cloned_instance.instance_ids
}

output "cloned_instance_public_ips" {
  description = "The public IPs of the cloned instances."
  value       = module.cloned_instance.public_ips
}
