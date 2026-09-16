output "public_ip" {
  description = "Point your A record here BEFORE the first boot, or Caddy gets no certificate."
  value       = aws_eip.this.public_ip
}

output "url" {
  description = "The console, once DNS has propagated and the bootstrap has finished."
  value       = "https://${var.domain}"
}

output "ssh" {
  description = "Watch the bootstrap: append \"sudo tail -f /var/log/talon-install.log\"."
  value       = "ssh talon@${aws_eip.this.public_ip}"
}

output "read_credentials" {
  description = "The generated secrets. ESCROW THE ENCRYPTION KEY — a restored database without it is ciphertext."
  value       = "ssh talon@${aws_eip.this.public_ip} 'sudo cat /root/talon-credentials.txt'"
}
