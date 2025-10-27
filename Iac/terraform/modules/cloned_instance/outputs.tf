# The IDs of the cloned instances.
output "instance_ids" {
  description = "The IDs of the cloned instances."
  value       = aws_instance.cloned_instance[*].id
}

# The public IPs of the cloned instances.
output "public_ips" {
  description = "The public IPs of the cloned instances."
  value       = aws_instance.cloned_instance[*].public_ip
}
