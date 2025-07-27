#!/usr/bin/env ruby

require 'fileutils'
require 'open3'
require 'json'

def setup_env_file
  puts "NHS Records Downloader - Setup"
  puts "=" * 50
  puts

  env_content = []
  
  # Ask about 1Password
  print "Are you using 1Password CLI? (y/n): "
  use_1password = gets.chomp.downcase == 'y'
  
  if use_1password
    setup_1password_config(env_content)
  else
    setup_manual_config(env_content)
  end
  
  # NHS Number
  nhs_number = nil
  loop do
    print "\nEnter your NHS number: "
    input = gets.chomp
    
    # Remove any spaces or non-digits
    digits_only = input.gsub(/\D/, '')
    
    if digits_only.length != 10
      puts "❌ NHS number must be exactly 10 digits (you entered #{digits_only.length})"
      next
    end
    
    # Format with spaces after 3rd and 6th digits
    nhs_number = "#{digits_only[0..2]} #{digits_only[3..5]} #{digits_only[6..9]}"
    puts "✅ NHS number formatted as: #{nhs_number}"
    break
  end
  
  env_content << "NHS_NUMBER=#{nhs_number}"
  
  # Write .env file
  File.write('.env', env_content.join("\n"))
  puts "\n✅ Created .env file successfully!"
  
  # Create .gitignore if it doesn't exist
  if !File.exist?('.gitignore') || !File.read('.gitignore').include?('.env')
    File.open('.gitignore', 'a') { |f| f.puts '.env' }
    puts "✅ Added .env to .gitignore"
  end
end

def setup_1password_config(env_content)
  # Check if 1Password CLI is installed
  stdout, stderr, status = Open3.capture3('op', '--version')
  unless status.success?
    puts "\n❌ 1Password CLI not found!"
    puts "Please install it first: brew install --cask 1password-cli"
    exit 1
  end
  
  # Check for multiple accounts
  stdout, stderr, status = Open3.capture3('op', 'account', 'list')
  if status.success?
    accounts = stdout.lines.drop(1).map do |line|
      parts = line.strip.split(/\s{2,}/)
      { url: parts[0], email: parts[1] } if parts.length >= 2
    end.compact
    
    if accounts.length > 1
      puts "\nMultiple 1Password accounts found:"
      accounts.each_with_index do |acc, i|
        puts "#{i + 1}. #{acc[:email]} (#{acc[:url]})"
      end
      
      print "\nSelect account number (1-#{accounts.length}): "
      choice = gets.chomp.to_i
      
      if choice < 1 || choice > accounts.length
        puts "Invalid choice"
        exit 1
      end
      
      selected_account = accounts[choice - 1]
      env_content << "# 1Password Account"
      env_content << "ONEPASSWORD_ACCOUNT=#{selected_account[:url]}"
      
      puts "\n✅ Selected account: #{selected_account[:email]}"
    elsif accounts.length == 1
      # Single account, use it automatically
      env_content << "# 1Password Account"
      env_content << "ONEPASSWORD_ACCOUNT=#{accounts.first[:url]}"
    end
  end
  
  # Check if signed in
  account_flag = accounts && accounts.length > 0 ? "--account #{accounts.first[:url]}" : ""
  stdout, stderr, status = Open3.capture3("op whoami #{account_flag}")
  unless status.success?
    puts "\n⚠️  You need to sign in to 1Password CLI first"
    puts "Run: eval $(op signin#{account_flag.empty? ? '' : ' ' + account_flag})"
    exit 1
  end
  
  print "\nEnter the name of your NHS login item in 1Password (e.g., 'NHS'): "
  item_name = gets.chomp
  
  # Verify the item exists and get its details
  stdout, stderr, status = Open3.capture3('op', 'item', 'get', item_name, '--format=json')
  
  if status.success?
    item = JSON.parse(stdout)
    puts "\n✅ Found 1Password item: #{item['title']}"
    puts "   ID: #{item['id']}"
    
    # Check fields to verify we have username/email and password
    email_field = nil
    password_field = nil
    
    item['fields'].each do |field|
      if field['value'] && field['value'].include?('@')
        email_field = field
      elsif field['type'] == 'CONCEALED' || field['label']&.downcase == 'password'
        password_field = field
      end
    end
    
    if email_field
      puts "   Email: #{email_field['value']}"
    else
      puts "   ⚠️  Warning: Could not find email field"
    end
    
    if password_field
      puts "   Password: [hidden]"
    else
      puts "   ⚠️  Warning: Could not find password field"
    end
    
    env_content << "# 1Password Configuration"
    env_content << "# Using UUID for reliability (item name: #{item['title']})"
    env_content << "ONEPASSWORD_NHS_ITEM=#{item['id']}"
  else
    puts "\n❌ Could not find 1Password item '#{item_name}'"
    puts "Error: #{stderr}"
    exit 1
  end
end

def setup_manual_config(env_content)
  print "\nEnter your NHS email address: "
  email = gets.chomp
  
  print "Enter your NHS password: "
  # Disable echo for password input
  system("stty -echo")
  password = gets.chomp
  system("stty echo")
  puts # New line after password
  
  env_content << "# NHS Login Credentials"
  env_content << "NHS_EMAIL=#{email}"
  env_content << "NHS_PASSWORD=#{password}"
end

# Run setup
setup_env_file