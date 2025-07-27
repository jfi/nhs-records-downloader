#!/usr/bin/env ruby

require 'selenium-webdriver'
require 'dotenv/load'
require 'fileutils'
require 'json'
require 'date'
require 'open3'
require 'timeout'
require 'securerandom'
require 'base64'
require 'digest'
require 'optparse'

class NHSRecordsDownloader
  def initialize(options = {})
    @options = options
    @download_dir = File.join(Dir.pwd, 'nhs_downloads')
    @use_1password = check_1password_available
    setup_download_directory
    check_rate_limit_lock
    load_download_history
    setup_driver
  end

  def check_1password_available
    stdout, stderr, status = Open3.capture3('op', '--version')
    if status.success?
      puts "✓ 1Password CLI detected"
      true
    else
      puts "⚠️  1Password CLI not found. Using environment variables."
      false
    end
  rescue
    false
  end

  def get_1password_credentials
    puts "Fetching credentials from 1Password..."
    
    # Get account from env if available
    account = ENV['ONEPASSWORD_ACCOUNT']
    account_flag = account ? "--account #{account}" : ""
    
    # First check if we're already signed in
    stdout, stderr, status = Open3.capture3("op whoami #{account_flag}")
    
    if !status.success?
      puts "❌ 1Password CLI is not signed in"
      puts "\n📝 To sign in to 1Password, run this command in your terminal:"
      puts "\n   eval $(op signin#{account ? ' --account ' + account : ''})"
      puts "\nThen run this script again."
      puts "\n💡 Tip: 1Password CLI sessions expire after 30 minutes of inactivity."
      exit 1
    end
    
    # Try to get NHS login item
    item_ref = ENV['ONEPASSWORD_NHS_ITEM'] || 'NHS Login'
    
    email = nil
    password = nil
    
    # Check if using secret reference format (op://vault/item/field)
    if item_ref.start_with?('op://')
      # Get individual fields using secret references
      email_ref = item_ref.sub(/\/[^\/]+$/, '/username')
      password_ref = item_ref.sub(/\/[^\/]+$/, '/password')
      
      # Try common field names for email
      ['username', 'email'].each do |field|
        ref = item_ref.sub(/\/[^\/]+$/, "/#{field}")
        stdout, stderr, status = Open3.capture3("op read #{ref} #{account_flag}")
        if status.success?
          email = stdout.strip
          break
        end
      end
      
      # Get password
      stdout, stderr, status = Open3.capture3("op read #{password_ref} #{account_flag}")
      password = stdout.strip if status.success?
    else
      # Get full item by name or UUID
      stdout, stderr, status = Open3.capture3("op item get '#{item_ref}' --format=json #{account_flag}")
      
      if status.success?
        item = JSON.parse(stdout)
        
        # Extract fields from 1Password item
        item['fields'].each do |field|
          # Check for email by looking for @ symbol
          if field['value'] && field['value'].include?('@')
            email = field['value']
          # Check for password by type or label
          elsif field['type'] == 'CONCEALED' || field['label']&.downcase == 'password'
            password = field['value']
          # Fallback to label matching
          elsif field['label']&.downcase&.match?(/username|email|e-mail/)
            email ||= field['value']
          end
        end
        
        # Also check for designated fields
        email ||= item['fields'].find { |f| f['purpose'] == 'USERNAME' }&.dig('value')
        password ||= item['fields'].find { |f| f['purpose'] == 'PASSWORD' }&.dig('value')
      else
        puts "Error fetching from 1Password: #{stderr}"
        puts "Make sure you have an item named '#{item_ref}' in 1Password"
        exit 1
      end
    end
    
    unless email && password
      puts "Error: Could not extract email and password from 1Password item"
      exit 1
    end
    
    return { email: email, password: password }
  end

  def setup_download_directory
    FileUtils.mkdir_p(@download_dir)
  end
  
  def check_rate_limit_lock
    lockfile_path = File.join(@download_dir, '.otp_rate_limit_lock')
    
    if File.exist?(lockfile_path)
      begin
        lock_data = JSON.parse(File.read(lockfile_path))
        unlock_time = Time.parse(lock_data['unlock_at'])
        
        if Time.now < unlock_time
          remaining_seconds = (unlock_time - Time.now).to_i
          remaining_minutes = (remaining_seconds / 60.0).ceil
          
          puts "\n" + "="*60
          puts "⚠️  OTP RATE LIMIT STILL IN EFFECT"
          puts "="*60
          puts "\nA previous attempt hit the OTP rate limit."
          puts "You must wait #{remaining_minutes} more minutes before trying again."
          puts "Unlock time: #{unlock_time.strftime('%H:%M:%S')}"
          puts "\nExiting to prevent another rate limit..."
          
          exit 1
        else
          # Lock expired, remove it
          File.delete(lockfile_path)
          puts "✓ Previous rate limit has expired, continuing..."
        end
      rescue => e
        # If we can't parse the lockfile, just remove it
        File.delete(lockfile_path)
      end
    end
  end
  
  def load_download_history
    @download_history_file = File.join(@download_dir, 'download_history.json')
    @download_history = {}
    
    if File.exist?(@download_history_file)
      begin
        @download_history = JSON.parse(File.read(@download_history_file))
        puts "✓ Loaded download history with #{@download_history.keys.length} entries"
      rescue => e
        puts "Warning: Could not load download history: #{e.message}"
        @download_history = {}
      end
    else
      puts "No download history found - starting fresh"
    end
  end
  
  def save_download_history
    File.open(@download_history_file, 'w') do |f|
      f.puts JSON.pretty_generate(@download_history)
    end
  end
  
  def document_already_downloaded?(document_id, document_title, document_date)
    # Create a unique key for this document
    key = generate_document_key(document_id, document_title, document_date)
    @download_history.key?(key)
  end
  
  def record_document_download(document_id, document_title, document_date, filename)
    key = generate_document_key(document_id, document_title, document_date)
    @download_history[key] = {
      title: document_title,
      date: document_date,
      filename: filename,
      downloaded_at: DateTime.now.to_s,
      id: document_id
    }
    save_download_history
  end
  
  def generate_document_key(document_id, title, date)
    # Use ID if available, otherwise use title and date
    if document_id && !document_id.empty?
      "doc_#{document_id}"
    else
      # Create a hash of title and date for uniqueness
      content = "#{title}_#{date}".downcase.gsub(/\s+/, '_')
      "doc_#{Digest::MD5.hexdigest(content)[0..12]}"
    end
  end

  def setup_driver
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--disable-blink-features=AutomationControlled')
    options.add_preference(:download, {
      prompt_for_download: false,
      default_directory: @download_dir
    })
    
    # Disable Chrome's password manager and autofill
    prefs = {
      'credentials_enable_service' => false,
      'profile.password_manager_enabled' => false,
      'profile.password_manager_leak_detection' => false,
      'autofill.profile_enabled' => false,
      'autofill.credit_card_enabled' => false,
      'profile.default_content_setting_values.notifications' => 2
    }
    options.add_preference(:prefs, prefs)
    
    # Additional arguments to disable Chrome features
    options.add_argument('--disable-save-password-bubble')
    options.add_argument('--disable-autofill-keyboard-accessory-view')
    options.add_argument('--disable-features=WebAuthn')
    options.add_argument('--disable-web-security')
    
    # Use incognito mode to avoid saved passwords
    options.add_argument('--incognito')
    
    @driver = Selenium::WebDriver.for :chrome, options: options
    @wait = Selenium::WebDriver::Wait.new(timeout: 30)
  end

  def login
    puts "Starting NHS login process..."
    puts "⚠️  Note: All credentials stay on your local machine only"
    
    # Get credentials
    if @use_1password
      creds = get_1password_credentials
      email = creds[:email]
      password = creds[:password]
    else
      email = ENV['NHS_EMAIL']
      password = ENV['NHS_PASSWORD']
    end
    
    unless email && password
      puts "Error: Missing email or password"
      exit 1
    end
    
    # Start from NHS homepage
    puts "Navigating to NHS homepage..."
    @driver.get('https://www.nhs.uk')
    sleep(2)
    
    # Handle cookie consent on homepage first
    handle_cookie_consent
    sleep(1)
    
    # Click My Account link
    begin
      # Try multiple selectors for My Account
      my_account_selectors = [
        'a.nhsuk-account__login--link',
        'a[href*="/nhs-app/account/"]',
        '.nhsuk-account__login a',
        'a:contains("My account")'
      ]
      
      my_account_link = nil
      my_account_selectors.each do |selector|
        begin
          if selector.include?(':contains')
            my_account_link = @driver.find_element(xpath: "//a[contains(text(), 'My account')]")
          else
            my_account_link = @driver.find_element(css: selector)
          end
          
          if my_account_link && my_account_link.displayed?
            puts "Clicking 'My account' link..."
            my_account_link.click
            sleep(2)
            break
          end
        rescue
          # Try next selector
        end
      end
      
      raise "Could not find My Account link" unless my_account_link
    rescue => e
      puts "Could not find My Account link: #{e.message}"
      puts "Trying alternate route..."
    end
    
    # Click Continue to NHS login button
    begin
      continue_button = @wait.until { @driver.find_element(css: 'a.nhsuk-button--login[href*="auth/redirect"]') }
      puts "Clicking 'Continue to NHS login' button..."
      continue_button.click
      sleep(2)
    rescue
      # If we can't find the button, navigate directly
      puts "Navigating directly to login page..."
      @driver.get('https://www.nhs.uk/auth/redirect?target=https://www.nhsapp.service.nhs.uk/patient')
      sleep(2)
    end
    
    # Handle cookie consent if it appears
    handle_cookie_consent
    
    # Check if we're on the NHS App login page with Continue button
    if @driver.current_url.include?('nhsapp.service.nhs.uk/login')
      begin
        continue_button = @wait.until { @driver.find_element(id: 'viewInstructionsButton') }
        puts "Clicking Continue button on NHS App login page..."
        continue_button.click
        sleep(1)
      rescue
        # Try alternate selector
        begin
          continue_button = @driver.find_element(css: 'button.Login_continueWithNhsLogin_OUNXI')
          continue_button.click
          sleep(1)
        rescue
          puts "Could not find Continue button on NHS App login page"
        end
      end
    end
    
    # Now we should be on the email entry page
    puts "Waiting for email entry page..."
    puts "⚠️  If Chrome shows a passkey popup, please click 'Cancel' manually"
    puts "Waiting up to 60 seconds for passkey popup to be cancelled..."
    
    # Wait for up to 60 seconds for the email field to become available
    email_field = nil
    wait_time = 60
    start_time = Time.now
    
    while (Time.now - start_time) < wait_time
      begin
        # Try to find the email field
        email_field = @driver.find_element(id: 'user-email')
        if email_field && email_field.displayed?
          puts "✓ Email field found after #{(Time.now - start_time).round} seconds"
          break
        end
      rescue
        # Field not found yet, keep waiting
      end
      
      # Also check for the old email field ID
      begin
        email_field = @driver.find_element(id: 'email')
        if email_field && email_field.displayed?
          puts "✓ Email field found (fallback) after #{(Time.now - start_time).round} seconds"
          break
        end
      rescue
        # Field not found yet, keep waiting
      end
      
      sleep(0.5)
    end
    
    if !email_field || !email_field.displayed?
      puts "❌ Email field not found after #{wait_time} seconds"
      puts "The passkey popup may still be blocking the page"
      raise "Could not find email field"
    end
    
    begin
      puts "Entering email..."
      email_field.send_keys(email)
      
      # Look for submit/continue button
      sleep(2)
      submit_selectors = [
        'button[type="submit"]',
        'button.nhsuk-button',
        'button[class*="submit"]',
        'button[class*="continue"]'
      ]
      
      continue_button = nil
      submit_selectors.each do |selector|
        begin
          buttons = @driver.find_elements(css: selector)
          continue_button = buttons.find { |b| b.displayed? && b.text.downcase.include?('continue') }
          
          if continue_button
            puts "Clicking Continue button after email..."
            continue_button.click
            break
          end
        rescue
          # Try next selector
        end
      end
      
      # Wait for page to load
      sleep(2)
    rescue => e
      puts "Error entering email: #{e.message}"
      puts "Current URL: #{@driver.current_url}"
      raise e
    end
    
    # Wait for next page after email submission
    puts "Waiting for next page after email submission..."
    sleep(3)
    
    # Keep checking for passkey prompts or password page
    max_attempts = 5
    attempt = 0
    
    while attempt < max_attempts
      attempt += 1
      puts "Attempt #{attempt}: Current URL: #{@driver.current_url}"
      
      # Check if we're on the passkey failure page
      if @driver.current_url.include?('passkey-login-failed') || 
         @driver.page_source.include?('There was a problem') ||
         @driver.page_source.include?('What do you want to do?')
        puts "Found passkey failure page, handling it..."
        handle_passkey_prompts
        sleep(2)
      end
      
      # Check if we're on password page
      if @driver.current_url.include?('log-in-password') || 
         page_has_element?(:id, 'password-input') || 
         page_has_element?(:id, 'password')
        puts "Found password page!"
        enter_password(password)
        break
      end
      
      # If we're still on email page, try clicking continue again
      if @driver.current_url.include?('enter-email')
        puts "Still on email page, looking for Continue button..."
        begin
          buttons = @driver.find_elements(css: 'button')
          continue_btn = buttons.find { |b| b.displayed? && b.text.downcase.include?('continue') }
          if continue_btn
            puts "Found and clicking Continue button again..."
            continue_btn.click
          end
        rescue
          # Ignore errors
        end
      end
      
      sleep(2)
    end
    
    if attempt >= max_attempts
      puts "Failed to reach password page after #{max_attempts} attempts"
      puts "Final URL: #{@driver.current_url}"
    end
    
    # Check if MFA is required
    if page_has_element?(:id, 'otp-input') || page_has_element?(:css, "input[data-qa='otp-input']")
      handle_mfa
    else
      puts "No MFA required, continuing..."
    end
    
    # After all authentication steps, verify login success
    verify_login_success
  end

  def handle_cookie_consent
    # First try the specific NHS cookie banner button
    begin
      accept_button = @driver.find_element(id: 'nhsuk-cookie-banner__link_accept_analytics')
      if accept_button && accept_button.displayed?
        puts "Accepting analytics cookies..."
        accept_button.click
        sleep(1)
        return
      end
    rescue
      # Button not found by ID
    end
    
    # Fallback to text-based search
    cookie_texts = [
      "I'm OK with analytics cookies",
      "Accept all cookies",
      "Accept cookies"
    ]
    
    cookie_texts.each do |text|
      begin
        # Try to find button with exact text
        elements = @driver.find_elements(xpath: "//button[contains(text(), '#{text}')]")
        
        elements.each do |element|
          if element.displayed?
            puts "Accepting cookies: '#{text}'"
            element.click
            sleep(1)
            return
          end
        end
      rescue => e
        # Continue trying other selectors
        puts "Cookie consent error: #{e.message}" if ENV['DEBUG']
      end
    end
  end

  def handle_passkey_prompts
    puts "Checking for passkey prompts..."
    
    # Give page time to fully load
    sleep(1)
    
    # Check if we're on the "There was a problem" page or passkey choice page
    page_source = @driver.page_source
    if page_source.include?("There was a problem") || 
       page_source.include?("We were unable to authenticate you") || 
       page_source.include?("What do you want to do?") ||
       page_source.include?("Log in using my password instead")
      
      puts "Found passkey authentication page - selecting password login..."
      puts "Current URL: #{@driver.current_url}"
      
      # Wait for the form to be fully loaded
      sleep(1)
      
      # Select "Log in using my password instead" radio button
      password_selected = false
      
      # Method 1: Try by ID
      begin
        password_radio = @driver.find_element(id: 'log-in-with-password')
        @driver.execute_script("arguments[0].scrollIntoView(true);", password_radio)
        password_radio.click
        puts "✓ Selected password option by ID"
        password_selected = true
      rescue => e
        puts "Could not select by ID: #{e.message}"
      end
      
      # Method 2: Try by clicking the label
      if !password_selected
        begin
          label = @driver.find_element(css: 'label[for="log-in-with-password"]')
          @driver.execute_script("arguments[0].scrollIntoView(true);", label)
          label.click
          puts "✓ Selected password option by label"
          password_selected = true
        rescue => e
          puts "Could not select by label: #{e.message}"
        end
      end
      
      # Method 3: JavaScript click
      if !password_selected
        begin
          @driver.execute_script("document.getElementById('log-in-with-password').click();")
          puts "✓ Selected password option by JavaScript"
          password_selected = true
        rescue => e
          puts "Could not select by JavaScript: #{e.message}"
        end
      end
      
      unless password_selected
        puts "❌ Failed to select password option"
      end
      
      sleep(0.5) # Brief pause after selecting radio
      
      # Click Continue button
      continue_clicked = false
      
      # Method 1: Try by data-qa attribute
      begin
        continue_button = @driver.find_element(css: "button[data-qa='passkey-failed-continue-button']")
        @driver.execute_script("arguments[0].scrollIntoView(true);", continue_button)
        continue_button.click
        puts "✓ Clicked Continue button by data-qa"
        continue_clicked = true
        sleep(1)
      rescue => e
        puts "Could not click by data-qa: #{e.message}"
      end
      
      # Method 2: Try any submit button
      if !continue_clicked
        begin
          continue_button = @driver.find_element(css: 'button[type="submit"]')
          @driver.execute_script("arguments[0].scrollIntoView(true);", continue_button)
          continue_button.click
          puts "✓ Clicked Continue button by type=submit"
          continue_clicked = true
          sleep(1)
        rescue => e
          puts "Could not click by type=submit: #{e.message}"
        end
      end
      
      # Method 3: Try by button text
      if !continue_clicked
        begin
          continue_button = @driver.find_element(xpath: "//button[contains(text(), 'Continue')]")
          @driver.execute_script("arguments[0].scrollIntoView(true);", continue_button)
          continue_button.click
          puts "✓ Clicked Continue button by text"
          continue_clicked = true
          sleep(1)
        rescue => e
          puts "Could not click by text: #{e.message}"
        end
      end
      
      unless continue_clicked
        puts "❌ Failed to click Continue button"
      end
      
      return
    end
    
    # Original passkey prompt handling
    passkey_dismiss_selectors = [
      'button:contains("Use password")',
      'button:contains("Continue with password")',
      'button:contains("Skip")',
      'button:contains("Not now")',
      'a:contains("Use password")',
      'a:contains("Continue with password")'
    ]
    
    passkey_dismiss_selectors.each do |selector|
      begin
        # Use XPath for text-based selectors
        if selector.include?(':contains')
          text = selector.match(/:contains\("(.+?)"\)/)[1]
          element_type = selector.split(':')[0]
          elements = @driver.find_elements(xpath: "//#{element_type}[contains(text(), '#{text}')]")
          
          elements.each do |element|
            if element.displayed?
              puts "Dismissing passkey prompt..."
              element.click
              sleep(1)
              return
            end
          end
        else
          element = @driver.find_element(css: selector)
          if element && element.displayed?
            puts "Dismissing passkey prompt..."
            element.click
            sleep(1)
            return
          end
        end
      rescue
        # Continue trying other selectors
      end
    end
  end

  def enter_password(password)
    puts "Entering password..."
    
    # Try the new password field selector first
    begin
      password_field = @wait.until { @driver.find_element(id: 'password-input') }
      puts "Found password field by id 'password-input'"
    rescue
      # Fallback to old selector
      begin
        password_field = @driver.find_element(id: 'password')
        puts "Found password field by id 'password'"
      rescue
        # Try by data-qa attribute
        password_field = @driver.find_element(css: "input[data-qa='password-input']")
        puts "Found password field by data-qa"
      end
    end
    
    password_field.send_keys(password)
    puts "Password entered"
    
    # Look for the Continue button
    begin
      submit_button = @driver.find_element(css: "button[data-qa='enter-password-submit-button']")
      puts "Found Continue button by data-qa"
    rescue
      # Fallback to generic submit button
      submit_button = @driver.find_element(css: 'button[type="submit"]')
      puts "Found Continue button by type=submit"
    end
    
    puts "Clicking Continue button..."
    submit_button.click
    
    # Wait a moment for page to load
    sleep(2)
  end

  def handle_mfa
    puts "\n⚠️  MFA code required!"
    puts "A 6-digit security code has been sent to your mobile phone."
    
    # Check if we're in an interactive terminal
    unless STDIN.tty?
      puts "❌ Not running in an interactive terminal. Cannot read MFA code."
      puts "Please run this script directly in your terminal."
      exit 1
    end
    
    # Wait up to 120 seconds for user to enter the code
    mfa_code = nil
    Timeout.timeout(120) do
      print "Please enter the 6-digit code: "
      STDOUT.flush
      mfa_code = gets.chomp
      
      # Validate it's 6 digits
      until mfa_code && mfa_code.match?(/^\d{6}$/)
        puts "Invalid code. Please enter exactly 6 digits."
        print "Please enter the 6-digit code: "
        STDOUT.flush
        mfa_code = gets.chomp
      end
    end
    
    # Find the MFA input field
    begin
      mfa_field = @driver.find_element(id: 'otp-input')
      puts "Found MFA field by id 'otp-input'"
    rescue
      # Try by data-qa attribute
      begin
        mfa_field = @driver.find_element(css: "input[data-qa='otp-input']")
        puts "Found MFA field by data-qa"
      rescue
        raise "Could not find MFA input field"
      end
    end
    
    # Enter the code
    mfa_field.send_keys(mfa_code)
    puts "Entered MFA code"
    
    # Find and click the Continue button
    begin
      submit_button = @driver.find_element(css: "button[data-qa='otp-submit']")
      puts "Found Continue button by data-qa"
    rescue
      # Fallback to generic submit button
      submit_button = @driver.find_element(css: 'button[type="submit"]')
      puts "Found Continue button by type=submit"
    end
    
    puts "Clicking Continue..."
    submit_button.click
    
    # Wait for page to load
    sleep(3)
    
    # Check if we got the "too many attempts" error
    page_source = @driver.page_source
    if page_source.include?("You cannot continue") && page_source.include?("too many times")
      puts "\n❌ Too many security code attempts!"
      puts "You must wait up to 15 minutes before trying again."
      puts "\nThis is an NHS security measure. Please:"
      puts "1. Wait 15 minutes"
      puts "2. Try running the script again"
      puts "\nAlternatively, you can try logging in with a passkey if you have one set up."
      raise "Too many MFA attempts - please wait 15 minutes"
    end
    
  rescue Timeout::Error
    puts "\n❌ Timeout waiting for MFA code (120 seconds)"
    raise "MFA code entry timeout"
  end

  def verify_login_success
    puts "Verifying login..."
    
    # Wait for page to load after MFA
    sleep(3)
    
    # Check for OTP rate limit page
    if @driver.current_url.include?('otp-requests-exceeded')
      handle_otp_rate_limit
      return
    end
    
    # Check for "too many attempts" error
    page_source = @driver.page_source
    if page_source.include?("You cannot continue") && page_source.include?("too many times")
      puts "\n❌ Too many security code attempts!"
      puts "You must wait up to 15 minutes before trying again."
      puts "\nThis is an NHS security measure. Please:"
      puts "1. Wait 15 minutes"
      puts "2. Try running the script again"
      puts "\nAlternatively, you can try logging in with a passkey if you have one set up."
      raise "Too many MFA attempts - please wait 15 minutes"
    end
    
    # Check for error page
    if @driver.current_url.include?('/error') || @driver.title.include?('Something went wrong')
      puts "❌ Login failed - error page detected"
      puts "URL: #{@driver.current_url}"
      puts "Title: #{@driver.title}"
      raise "Login failed with error page. This may be due to expired MFA code or session timeout. Please try again."
    end
    
    # Check if we're on the "Access your NHS services" page
    max_attempts = 3
    attempt = 0
    
    while attempt < max_attempts
      attempt += 1
      puts "Login verification attempt #{attempt}"
      
      # Check current state
      current_url = @driver.current_url
      page_source = @driver.page_source
      
      # If we hit an error page, fail fast
      if current_url.include?('/error') || @driver.title.include?('Something went wrong')
        raise "Login failed - reached error page"
      end
      
      # Check for "Access your NHS services" page
      if page_source.include?("Access your NHS services")
        puts "Found 'Access your NHS services' page"
        
        # Look for the Continue button
        begin
          continue_button = @driver.find_element(id: 'viewInstructionsButton')
          puts "Clicking Continue button..."
          continue_button.click
          sleep(3)
        rescue
          # Try alternate selector
          begin
            continue_button = @driver.find_element(css: 'button.Login_continueWithNhsLogin_OUNXI')
            continue_button.click
            sleep(3)
          rescue => e
            puts "Could not find Continue button on NHS services page: #{e.message}"
          end
        end
      end
      
      # Wait a moment for page to settle
      sleep(2)
      
      # Check if we're now on the patient page
      if current_url.include?('nhsapp.service.nhs.uk/patient') || current_url.include?('nhsapp.service.nhs.uk/home')
        break
      end
    end
    
    # Clean up URL if it has authentication parameters
    if @driver.current_url.include?('assertedLoginIdentity')
      puts "Cleaning up URL with auth parameters..."
      base_url = 'https://www.nhsapp.service.nhs.uk/patient/'
      @driver.get(base_url)
      sleep(3)
    end
    
    # Final verification
    nhs_number = ENV['NHS_NUMBER']
    page_source = @driver.page_source
    nhs_number_no_spaces = nhs_number.gsub(' ', '')
    
    if page_source.include?(nhs_number) || page_source.include?(nhs_number_no_spaces) || 
       page_source.include?("Good morning") || page_source.include?("Good afternoon") || 
       page_source.include?("Good evening") || page_source.include?("Services") ||
       page_source.include?("Your health")
      puts "✓ Login successful!"
      puts "✓ Current URL: #{@driver.current_url}"
      
      # If we can find the NHS number, print it
      if page_source.include?(nhs_number) || page_source.include?(nhs_number_no_spaces)
        puts "✓ Found NHS number: #{nhs_number}"
      end
    else
      puts "⚠️  Warning: Could not fully verify login"
      puts "Current URL: #{@driver.current_url}"
      puts "Page title: #{@driver.title}"
      # Continue anyway as we might be logged in
    end
  end

  def page_has_element?(method, locator)
    begin
      @driver.find_element(method, locator)
      true
    rescue Selenium::WebDriver::Error::NoSuchElementError
      false
    end
  end
  
  def handle_otp_rate_limit
    puts "\n" + "="*60
    puts "❌ OTP RATE LIMIT DETECTED"
    puts "="*60
    puts "\nYou have exceeded the number of allowed security code requests."
    puts "The NHS requires you to wait before trying again."
    puts "\nThe script will now wait for 15 minutes..."
    puts "Time started: #{Time.now.strftime('%H:%M:%S')}"
    
    # Create a lockfile to prevent running again too soon
    lockfile_path = File.join(@download_dir, '.otp_rate_limit_lock')
    File.open(lockfile_path, 'w') do |f|
      f.puts({
        locked_at: Time.now.to_s,
        unlock_at: (Time.now + 900).to_s  # 15 minutes
      }.to_json)
    end
    
    # Wait with progress updates
    15.times do |minute|
      remaining = 15 - minute
      puts "\r⏳ Waiting... #{remaining} minutes remaining     "
      STDOUT.flush
      sleep(60)
    end
    
    puts "\n\n✓ 15 minute wait completed!"
    puts "Time now: #{Time.now.strftime('%H:%M:%S')}"
    
    # Remove lockfile
    File.delete(lockfile_path) if File.exist?(lockfile_path)
    
    puts "\nPlease run the script again to retry."
    puts "The rate limit should now be cleared."
    
    raise "OTP rate limit - 15 minute wait completed. Please run the script again."
  end

  def navigate_to_gp_records
    puts "Navigating to GP records..."
    
    # Wait for page to be ready
    sleep(2)
    
    # Click on "GP health record" link
    begin
      # Try by data-qa attribute first
      gp_record_link = @driver.find_element(css: "li[data-qa='home-panel-link-gp-medical-records'] a")
      puts "Found GP health record link by data-qa"
      gp_record_link.click
      sleep(2)
    rescue
      begin
        # Try by href
        gp_record_link = @driver.find_element(css: "a[href='/patient/health-records/gp-medical-record']")
        puts "Found GP health record link by href"
        gp_record_link.click
        sleep(2)
      rescue
        # Try by text
        begin
          gp_record_link = @driver.find_element(xpath: "//a[contains(text(), 'GP health record')]")
          puts "Found GP health record link by text"
          gp_record_link.click
          sleep(2)
        rescue => e
          puts "Could not find GP health record link: #{e.message}"
          puts "Current URL: #{@driver.current_url}"
          puts "Page source sample: #{@driver.page_source[0..500]}"
          return false
        end
      end
    end
    
    # Handle the warning/consent page with Continue button
    if @driver.page_source.include?("Important") && @driver.page_source.include?("Your record may contain sensitive information")
      puts "Found GP records consent page"
      begin
        continue_button = @driver.find_element(css: "button[data-qa='nhsuk-continue-button']")
        puts "Clicking Continue on consent page..."
        continue_button.click
        sleep(2)
      rescue
        # Try generic Continue button
        begin
          continue_button = @driver.find_element(xpath: "//button[text()='Continue']")
          continue_button.click
          sleep(2)
        rescue => e
          puts "Could not find Continue button: #{e.message}"
        end
      end
      
      # Extra wait for JavaScript to load
      puts "Waiting for page to fully load..."
      sleep(2)
    end
    
    # Verify we're on the GP health record page
    if @driver.page_source.include?("Your GP health record") || @driver.page_source.include?("NHS number:")
      puts "✓ Successfully navigated to GP health record page"
      puts "Current URL: #{@driver.current_url}"
      
      # Verify NHS number is displayed
      nhs_number = ENV['NHS_NUMBER']
      if nhs_number && @driver.page_source.include?(nhs_number.gsub(' ', ''))
        puts "✓ NHS number verified: #{nhs_number}"
      end
      
      return true
    else
      puts "Warning: May not be on GP records page"
      puts "Current URL: #{@driver.current_url}"
      return false
    end
  end

  def download_records
    puts "Starting record downloads..."
    
    # Wait for page to fully load
    sleep(3)
    
    # Define all available sections
    all_sections = [
      { name: "Documents", href: "documents", data_purpose: "documents" },
      { name: "Consultations and events", href: "events", data_purpose: "events" },
      { name: "Test results", href: "test-results-v2", data_purpose: "test-results" }
    ]
    
    # Filter sections based on options
    sections = if @options[:sections] && !@options[:sections].empty?
      selected = @options[:sections]
      all_sections.select do |section|
        selected.any? { |s| section[:name].downcase.include?(s.downcase) }
      end
    else
      all_sections
    end
    
    if sections.empty?
      puts "No matching sections found for: #{@options[:sections].join(', ')}"
      return
    end
    
    puts "Will download: #{sections.map { |s| s[:name] }.join(', ')}"
    
    sections.each do |section|
      puts "\n" + "="*50
      puts "Processing: #{section[:name]}"
      puts "="*50
      
      begin
        # Click on the section link
        section_link = nil
        
        # Try multiple methods to find the link
        
        # Method 1: By data-purpose attribute
        begin
          section_link = @driver.find_element(css: "li[data-purpose='#{section[:data_purpose]}'] a")
          puts "Found link by data-purpose"
        rescue
          # Method 2: By href
          begin
            section_link = @driver.find_element(css: "a[href*='#{section[:href]}']")
            puts "Found link by href"
          rescue
            # Method 3: By link text in span
            begin
              section_link = @driver.find_element(xpath: "//a[.//span[contains(text(), '#{section[:name]}')]]")
              puts "Found link by span text"
            rescue
              # Method 4: Simple text search
              begin
                section_link = @driver.find_element(link_text: section[:name])
                puts "Found link by link text"
              rescue => e
                puts "Could not find link with any method"
                puts "Current URL: #{@driver.current_url}"
                # Debug: print available links
                links = @driver.find_elements(css: "li[data-purpose] a")
                puts "Available links found:"
                links.each do |link|
                  begin
                    puts "  - #{link.text}"
                  rescue
                    # Ignore stale elements
                  end
                end
              end
            end
          end
        end
        
        if section_link
          puts "Clicking on #{section[:name]} link..."
          @driver.execute_script("arguments[0].scrollIntoView(true);", section_link)
          sleep(1)
          section_link.click
          sleep(3)
          
          # Call appropriate download method based on section
          case section[:name]
          when "Test results"
            download_test_results
          when "Consultations and events"
            download_consultations
          when "Documents"
            download_documents
          end
          
          # Navigate back to main GP records page
          puts "Navigating back to GP records page..."
          # For test results, we need to navigate to the main page directly
          # as we may be several pages deep after year navigation
          if section[:name] == "Test results"
            @driver.get('https://www.nhsapp.service.nhs.uk/patient/health-records/gp-medical-record')
            sleep(3)
          else
            @driver.navigate.back
            sleep(3)
          end
        else
          puts "❌ Could not find #{section[:name]} link"
        end
        
      rescue => e
        puts "Error processing #{section[:name]}: #{e.message}"
        puts "Backtrace: #{e.backtrace.first(3).join("\n")}"
      end
    end
    
    puts "\n✓ Finished processing all sections"
  end
  
  def download_test_results
    puts "Downloading test results..."
    
    begin
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      all_test_results = []
      
      # Wait for page to load
      sleep(2)
      
      if @options[:verbose]
        puts "Current URL: #{@driver.current_url}"
        puts "Page title: #{@driver.title}"
      end
      
      # Check current year from page
      current_year = nil
      begin
        sub_heading = @driver.find_element(css: "p[data-qa='page-sub-heading']")
        if sub_heading.text.match(/Showing results from (\d{4})/)
          current_year = $1
          puts "Currently viewing results from #{current_year}"
        end
      rescue
        puts "Could not determine current year"
      end
      
      # Process current page
      puts "\nProcessing main test results page..."
      results = extract_test_results_from_page
      puts "Found #{results.length} test results on main page"
      all_test_results.concat(results)
      
      # Check for "View all test results" link
      begin
        view_all_link = @driver.find_element(css: "div#view-older-results a")
        if view_all_link && view_all_link.displayed?
          puts "\nFound 'View all test results' link - clicking to access other years..."
          view_all_link.click
          sleep(2)
          
          # We're now on the year selection page
          # Extract available years and process each
          process_test_results_by_year(all_test_results)
        else
          puts "View all test results link found but not displayed"
        end
      rescue => e
        puts "No 'View all test results' link found - only current year available"
        puts "Error: #{e.message}" if @options[:verbose]
      end
      
      puts "\n✓ Extracted #{all_test_results.length} test results in total"
      
      # Save test results
      save_test_results_data(all_test_results)
      
    rescue => e
      puts "Error in download_test_results: #{e.message}"
      puts e.backtrace.first(3).join("\n")
    end
  end
  
  def extract_test_results_from_page
    results = []
    wait = Selenium::WebDriver::Wait.new(timeout: 10)
    
    begin
      # Try to find test result groups (by month) - new structure
      groups = @driver.find_elements(css: "section[data-qa='test-results-group']")
      
      if groups.empty?
        # Check for year-specific page structure
        puts "Checking for year-specific test results page..."
        
        # Look for the legacy format used in year pages
        month_groups = @driver.find_elements(css: "div[data-purpose='record-item']")
        
        if month_groups.any?
          puts "Found #{month_groups.length} month groups in year view"
          
          # Process each month group
          month_groups.each_with_index do |month_group, group_index|
            begin
              # Extract month heading
              month_heading = month_group.find_element(css: "h3[data-purpose='record-group-header']").text rescue "Unknown Month"
              
              # Find all test result cards in this month
              test_cards = month_group.find_elements(css: "li[data-qa='test-results-card']")
              puts "Found #{test_cards.length} test results in #{month_heading}"
              
              # Extract all test info before clicking any (to avoid stale elements)
              test_info = []
              test_cards.each_with_index do |card, card_index|
                begin
                  # Extract test name and URL
                  link = card.find_element(css: "a")
                  test_url = link.attribute("href")
                  
                  # Extract test name from span
                  name_elem = card.find_element(css: "span[data-qa='test-result-name']")
                  test_name = name_elem.text.strip
                  
                  # Extract date
                  date_elem = card.find_element(css: "p[data-qa='test-result-date']")
                  test_date = date_elem.text.strip
                  
                  test_info << {
                    name: test_name,
                    date: test_date,
                    url: test_url,
                    month_group: month_heading,
                    index: card_index
                  }
                rescue => e
                  puts "Error extracting test info at index #{card_index}: #{e.message}"
                end
              end
              
              puts "Extracted info for #{test_info.length} tests"
              
              # Now process each test if getting details
              test_info.each do |test|
                begin
                  details = {}
                  
                  if !@options[:skip_details]
                    # Re-find the month group and card
                    current_month_groups = @driver.find_elements(css: "div[data-purpose='record-item']")
                    current_month_group = current_month_groups[group_index]
                    
                    if current_month_group
                      current_cards = current_month_group.find_elements(css: "li[data-qa='test-results-card']")
                      if test[:index] < current_cards.length
                        card = current_cards[test[:index]]
                        link = card.find_element(css: "a")
                        
                        puts "Processing: #{test[:name]} - #{test[:date]}"
                        link.click
                        sleep(2)
                        
                        # Extract test details
                        details = extract_individual_test_result
                        
                        # Navigate back
                        @driver.navigate.back
                        sleep(2)
                      end
                    end
                  else
                    puts "Found: #{test[:name]} - #{test[:date]} (skipping details)"
                  end
                  
                  # Add to results
                  results << {
                    name: test[:name],
                    date: test[:date],
                    month_group: test[:month_group],
                    url: test[:url],
                    details: details
                  }
                  
                rescue => e
                  puts "Error processing test '#{test[:name]}': #{e.message}"
                  # Try to navigate back if we're stuck
                  @driver.navigate.back rescue nil
                  sleep(2)
                  
                  # Still add the test with basic info
                  results << {
                    name: test[:name],
                    date: test[:date],
                    month_group: test[:month_group],
                    url: test[:url],
                    details: {}
                  }
                end
              end
              
            rescue => e
              puts "Error processing month group #{group_index}: #{e.message}"
            end
          end
        else
          # Fallback: look for test result cards directly without groups
          puts "No month groups found, looking for individual cards..."
          cards = @driver.find_elements(css: "li.nhsapp-card[data-qa='test-result-card']")
          
          if cards.empty?
            puts "No test result cards found on this page"
            return results
          end
          
          puts "Found #{cards.length} test result cards"
          
          # Process cards without groups
          cards.each_with_index do |card, index|
            begin
              # Extract test name
              link = card.find_element(css: "a.nhsapp-card__link")
              test_name = link.text.strip
              test_url = link.attribute("href")
              
              # Extract date
              date_elem = card.find_element(css: "p[data-qa='test-result-date']")
              test_date = date_elem.text.strip
              
              # Extract details unless skipping
              details = {}
              if !@options[:skip_details]
                # Click on the test to get details
                puts "Processing: #{test_name} - #{test_date}"
                link.click
                sleep(2)
                
                # Extract test details
                details = extract_individual_test_result
                
                # Navigate back
                @driver.navigate.back
                sleep(2)
              else
                puts "Found: #{test_name} - #{test_date} (skipping details)"
              end
              
              # Add to results
              results << {
                name: test_name,
                date: test_date,
                month_group: "Ungrouped",
                url: test_url,
                details: details
              }
              
              # Re-find cards to avoid stale references
              cards = @driver.find_elements(css: "li.nhsapp-card[data-qa='test-result-card']")
              
            rescue => e
              puts "Error processing test result #{index + 1}: #{e.message}"
              # Try to navigate back if we're stuck
              @driver.navigate.back rescue nil
              sleep(2)
            end
          end
        end
      else
        # Process with groups as before
        groups.each_with_index do |group, group_index|
          begin
            # Extract month/year from group heading
            month_heading = group.find_element(css: "h2[data-qa='test-results-group-heading']").text
            
            # Find all test result cards in this group
            cards = group.find_elements(css: "li.nhsapp-card[data-qa='test-result-card']")
            puts "Found #{cards.length} test results in #{month_heading}"
            
            # Extract all test info before clicking any (to avoid stale elements)
            test_info = []
            cards.each_with_index do |card, card_index|
              begin
                # Extract test name
                link = card.find_element(css: "a.nhsapp-card__link")
                test_name = link.text.strip
                test_url = link.attribute("href")
                
                # Extract date
                date_elem = card.find_element(css: "p[data-qa='test-result-date']")
                test_date = date_elem.text.strip
                
                test_info << {
                  name: test_name,
                  date: test_date,
                  url: test_url,
                  month_group: month_heading,
                  index: card_index
                }
              rescue => e
                puts "Error extracting test info at index #{card_index}: #{e.message}"
              end
            end
            
            puts "Extracted info for #{test_info.length} tests"
            
            # Now process each test if getting details
            test_info.each do |test|
              begin
                details = {}
                
                if !@options[:skip_details]
                  # Re-find the group and card
                  current_groups = @driver.find_elements(css: "section[data-qa='test-results-group']")
                  if group_index < current_groups.length
                    current_group = current_groups[group_index]
                    current_cards = current_group.find_elements(css: "li.nhsapp-card[data-qa='test-result-card']")
                    
                    if test[:index] < current_cards.length
                      card = current_cards[test[:index]]
                      link = card.find_element(css: "a.nhsapp-card__link")
                      
                      puts "Processing: #{test[:name]} - #{test[:date]}"
                      link.click
                      sleep(2)
                      
                      # Extract test details
                      details = extract_individual_test_result
                      
                      # Navigate back
                      @driver.navigate.back
                      sleep(2)
                    end
                  end
                else
                  puts "Found: #{test[:name]} - #{test[:date]} (skipping details)"
                end
                
                # Add to results
                results << {
                  name: test[:name],
                  date: test[:date],
                  month_group: test[:month_group],
                  url: test[:url],
                  details: details
                }
                
              rescue => e
                puts "Error processing test '#{test[:name]}': #{e.message}"
                # Try to navigate back if we're stuck
                @driver.navigate.back rescue nil
                sleep(2)
                
                # Still add the test with basic info
                results << {
                  name: test[:name],
                  date: test[:date],
                  month_group: test[:month_group],
                  url: test[:url],
                  details: {}
                }
              end
            end
            
          rescue => e
            puts "Error processing group #{group_index}: #{e.message}"
          end
        end
      end
      
    rescue => e
      puts "Error extracting test results: #{e.message}"
    end
    
    results
  end
  
  def extract_individual_test_result
    details = {}
    
    begin
      # Extract all the table data
      table_rows = @driver.find_elements(css: "tr#testResultData")
      
      table_rows.each do |row|
        cells = row.find_elements(css: "td")
        if cells.length >= 2
          key = cells[0].text.strip
          value = cells[1].text.strip
          details[key] = value
        end
      end
      
      # Extract the full text content including specimen and investigation details
      result_span = @driver.find_element(css: "span[data-qa='result-details']")
      full_text = result_span.text
      
      # Parse specimen details
      if full_text.match(/Specimen\n(.+?)(?:\n\n|Pathology Investigations)/m)
        specimen_text = $1
        details["Specimen"] = specimen_text.gsub(/\n/, "; ")
      end
      
      # Parse pathology investigations
      if full_text.match(/Pathology Investigations\n(.+?)(?:\n\n|General Information)/m)
        investigations_text = $1
        details["Investigations"] = investigations_text.strip
      end
      
      # Parse general information section
      if full_text.match(/General Information\n(.+?)(?:\n\n|Message Recipient)/m)
        general_info = $1
        details["General Information"] = general_info.gsub(/\n/, "; ")
      end
      
    rescue => e
      puts "Error extracting test details: #{e.message}"
    end
    
    details
  end
  
  def process_test_results_by_year(all_test_results)
    begin
      # Find year links on the year selection page
      year_links = @driver.find_elements(css: "a.nhsapp-card__link")
      available_years = []
      
      year_links.each do |link|
        if link.text.match(/^\d{4}$/)
          available_years << link.text
        end
      end
      
      puts "Found test results for years: #{available_years.join(', ')}"
      
      # Process each year
      available_years.each do |year|
        puts "\nProcessing year #{year}..."
        
        # Click on the year
        year_link = @driver.find_element(xpath: "//a[text()='#{year}']")
        year_link.click
        sleep(2)
        
        # Extract results for this year
        results = extract_test_results_from_page
        all_test_results.concat(results)
        
        # Navigate back to year selection
        @driver.navigate.back
        sleep(2)
      end
      
    rescue => e
      puts "Error processing years: #{e.message}"
    end
  end
  
  def save_test_results_data(test_results)
    # Save as JSON
    json_path = File.join(@download_dir, "test_results.json")
    File.open(json_path, 'w') do |f|
      f.puts JSON.pretty_generate(test_results)
    end
    puts "✓ Saved test results to: #{json_path}"
    
    # Save as CSV
    csv_path = File.join(@download_dir, "test_results.csv")
    require 'csv'
    
    CSV.open(csv_path, 'w') do |csv|
      # Header row
      csv << ['Date', 'Test Name', 'Month Group', 'Result', 'Follow up action', 
              'Clinician viewed', 'Result type', 'Tests', 'Filed by', 
              'Specimen', 'Investigations', 'General Information']
      
      # Data rows
      test_results.each do |result|
        details = result[:details] || {}
        csv << [
          result[:date],
          result[:name],
          result[:month_group],
          details['Result'],
          details['Follow up action'],
          details['Clinician viewed'],
          details['Result type'],
          details['Tests'],
          details['Filed by'],
          details['Specimen'],
          details['Investigations'],
          details['General Information']
        ]
      end
    end
    puts "✓ Saved test results to: #{csv_path}"
    
    # Generate summary
    puts "\nTest Results Summary:"
    puts "- Total test results: #{test_results.length}"
    
    # Count by test type
    test_types = Hash.new(0)
    test_results.each do |result|
      # Extract test type from name (e.g., "Pathology - Serum vitamin B12 level")
      if result[:name].match(/^(.+?)\s*-\s*(.+)/)
        test_category = $1
        test_types[test_category] += 1
      end
    end
    
    if test_types.any?
      puts "\nTest categories:"
      test_types.sort_by { |type, count| -count }.each do |type, count|
        puts "  - #{type}: #{count}"
      end
    end
  end
  
  def download_consultations
    puts "Downloading consultations and events..."
    
    begin
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      consultations = []
      
      # Wait for the page to load
      sleep(2)
      
      # Find all consultation cards
      cards = @driver.find_elements(css: "div.MedicalRecordCardGroupItem_nhsuk-card-group__item_Kk8X9")
      
      if cards.empty?
        puts "No consultations found"
        return
      end
      
      puts "Found #{cards.length} consultation records"
      
      cards.each_with_index do |card, index|
        begin
          # Extract date
          date_elem = card.find_element(css: "p[data-purpose='record-item-header']")
          date = date_elem.text.strip
          
          # Extract surgery and staff details
          detail_elem = card.find_element(css: "p[data-purpose='record-item-detail']")
          detail_text = detail_elem.text.strip
          
          # Parse surgery and staff from detail text
          # Format: "Surgery Name (Type) - Staff Name (Role)"
          if detail_text.match(/^(.+?)\s*\((.+?)\)\s*-\s*(.+?)\s*\((.+?)\)/)
            surgery = $1.strip
            surgery_type = $2.strip
            staff_name = $3.strip
            staff_role = $4.strip
          else
            surgery = detail_text
            surgery_type = ""
            staff_name = ""
            staff_role = ""
          end
          
          # Extract all entries
          entries = []
          entry_elements = card.find_elements(css: "ul.nhsuk-list--bullet li")
          
          entry_elements.each do |entry_elem|
            entry_text = entry_elem.text.strip
            
            # Parse entry type and details
            if entry_text.match(/^(.+?)\s*-\s*(.+)/)
              entry_type = $1.strip
              entry_details = $2.strip
              
              # Extract code if present (e.g., "(XaVzt)")
              code_match = entry_details.match(/\(([A-Za-z0-9]+)\)/)
              code = code_match ? code_match[1] : nil
              
              entries << {
                type: entry_type,
                details: entry_details,
                code: code
              }
            else
              entries << {
                type: "Unknown",
                details: entry_text,
                code: nil
              }
            end
          end
          
          # Add to consultations array
          consultation = {
            date: date,
            surgery: surgery,
            surgery_type: surgery_type,
            staff_name: staff_name,
            staff_role: staff_role,
            entries: entries
          }
          
          consultations << consultation
          
          # Progress indicator
          if (index + 1) % 10 == 0
            puts "Processed #{index + 1} consultations..."
          end
          
        rescue => e
          puts "Error processing consultation #{index + 1}: #{e.message}"
        end
      end
      
      puts "\n✓ Extracted #{consultations.length} consultations"
      
      # Save consultations to files
      save_consultations_data(consultations)
      
    rescue => e
      puts "Error in download_consultations: #{e.message}"
      puts e.backtrace.first(3).join("\n")
    end
  end
  
  def download_documents
    puts "Downloading documents..."
    
    begin
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      
      # Track processed documents and failures
      processed_count = 0
      skipped_documents = []
      page_number = 1
      
      loop do
        # Find all document items in the current page
        begin
          doc_container = wait.until { @driver.find_element(css: "div.nhsuk-grid-column-full ul") }
          doc_items = doc_container.find_elements(css: "li.MenuItem_listMenuItem_iXt37")
        rescue => e
          puts "Could not find document list: #{e.message}"
          break
        end
        
        if doc_items.empty?
          puts "No documents found on page #{page_number}"
          break
        end
        
        puts "\nPage #{page_number}: Found #{doc_items.length} documents"
        
        doc_items.each_with_index do |item, index|
        begin
          # Re-find elements to avoid stale references
          doc_container = @driver.find_element(css: "div.nhsuk-grid-column-full ul")
          current_items = doc_container.find_elements(css: "li.MenuItem_listMenuItem_iXt37")
          
          if index >= current_items.length
            puts "Document list changed, skipping remaining items"
            break
          end
          
          current_item = current_items[index]
          
          # Extract title/date from the item
          title_span = current_item.find_element(css: "span[aria-label]")
          title_text = title_span.attribute("aria-label")
          
          # Extract document ID from link if available
          link = current_item.find_element(css: "a")
          doc_url = link.attribute("href")
          doc_id = doc_url.split('/').last if doc_url
          
          # Parse date from title
          date_match = title_text.match(/(\d{1,2}\s+\w+\s+\d{4})/)
          doc_date = date_match ? date_match[1] : "Unknown"
          
          # Check if already downloaded
          if document_already_downloaded?(doc_id, title_text, doc_date)
            puts "\n#{index + 1}. Skipping (already downloaded): #{title_text}"
            next
          end
          
          # Check for API error documents
          begin
            p_elem = current_item.find_element(css: "p")
            if p_elem.text.include?("COM/API/") || p_elem.text.include?("PATIENTUPLOAD")
              puts "\n#{index + 1}. Skipping API error document: #{title_text}"
              puts "   Reason: Document appears to be an upload error (#{p_elem.text})"
              skipped_documents << {
                title: title_text,
                reason: "API upload error",
                details: p_elem.text
              }
              next
            end
          rescue
            # No paragraph element, continue normally
          end
          
          puts "\n#{index + 1}. Processing: #{title_text}"
          
          # Click on the document
          @driver.execute_script("arguments[0].scrollIntoView(true);", link)
          sleep(0.5) # Brief pause after scrolling
          link.click
          
          # Wait for page to load
          begin
            wait.until { @driver.find_element(css: "div[data-qa='beta-template-page-title']") }
          rescue
            puts "Page load timeout, continuing anyway"
          end
          sleep(1)
          
          # Check if document is unavailable
          page_title = @driver.find_element(css: "div[data-qa='beta-template-page-title'] h1").text rescue ""
          if page_title.include?("is not available through the NHS App")
            handle_unavailable_document(title_text, skipped_documents)
          else
            # Process the individual document
            result = download_individual_document(title_text, doc_id, doc_date)
            if result == :failed
              skipped_documents << {
                title: title_text,
                reason: "Download failed",
                details: "Could not find download or view options"
              }
            end
          end
          
          # Navigate back to documents list
          puts "Navigating back to documents list..."
          @driver.navigate.back
          sleep(2)
          
          # Verify we're back on the documents page
          unless @driver.current_url.include?('documents')
            puts "Navigation lost, returning to documents section"
            # Try to get back to documents
            begin
              @driver.get('https://www.nhsapp.service.nhs.uk/patient/health-records/gp-medical-record/documents')
              sleep(2)
            rescue
              puts "Failed to navigate back to documents"
              break
            end
          end
          
        rescue => e
          puts "Error processing document #{index + 1}: #{e.message}"
          skipped_documents << {
            title: title_text || "Unknown document",
            reason: "Processing error",
            details: e.message
          }
          # Try to navigate back if we're stuck
          @driver.navigate.back rescue nil
          sleep(2)
        end
      end
      
      processed_count += doc_items.length
      
      # Check for pagination - look for "Next" button
      begin
        next_button = @driver.find_element(xpath: "//a[contains(@class, 'nhsuk-pagination__link--next')]")
        if next_button.displayed?
          puts "\nNavigating to next page..."
          next_button.click
          sleep(2)
          page_number += 1
        else
          break
        end
      rescue
        # No next button found, we're done
        puts "\nNo more pages found"
        break
      end
    end
    
    puts "\n✓ Processed #{processed_count} documents in total"
    
    # Generate summary report
    if skipped_documents.any?
      generate_skipped_documents_report(skipped_documents)
    end
      
    rescue => e
      puts "Error in download_documents: #{e.message}"
    end
  end
  
  def download_individual_document(title_text, doc_id, doc_date)
    begin
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      
      # Extract document type and date from page title
      page_title = wait.until { @driver.find_element(css: "div[data-qa='beta-template-page-title'] h1") }
      full_title = page_title.text
      
      # Parse date from title (e.g., "Letter added on 21 July 2025")
      date_match = full_title.match(/(\d{1,2}\s+\w+\s+\d{4})/)
      if date_match
        date_str = date_match[1]
        formatted_date = parse_date_to_filename(date_str)
      else
        formatted_date = Date.today.strftime('%Y-%m-%d')
      end
      
      # Extract document type (first word)
      doc_type = full_title.split.first || "Document"
      
      # Look for action menu
      action_menu = wait.until { @driver.find_element(css: "ul[data-sid='action-list-menu']") }
      
      # Check for download button
      begin
        download_btn = action_menu.find_element(css: "a#btn_downloadDocument")
        
        # Get file extension from the paragraph that follows within the parent div
        parent_div = download_btn.find_element(xpath: "..")
        file_type_elem = parent_div.find_element(css: "p")
        file_extension = file_type_elem.text.gsub(/[()]/, '').downcase
        
        puts "Found download button for #{file_extension.upcase} file"
        
        # Generate filename
        filename = generate_document_filename(formatted_date, doc_type, file_extension)
        
        # Click download
        download_btn.click
        
        # Wait for download and rename
        wait_for_download_and_rename(filename)
        
        # Record successful download
        record_document_download(doc_id, title_text, doc_date, filename)
        
        return :success
        
      rescue Selenium::WebDriver::Error::NoSuchElementError
        # No download button, check for view button (likely an image)
        begin
          view_btn = action_menu.find_element(css: "a#btn_viewDocument")
          puts "Found view button - checking for embedded image"
          
          view_btn.click
          sleep(2)
          
          # Look for embedded image
          img_container = wait.until { @driver.find_element(css: "div#documentContainer img") }
          img_src = img_container.attribute("src")
          
          if img_src.start_with?("data:image/")
            # Parse data URL
            match = img_src.match(/data:image\/(\w+);base64,(.+)/)
            if match
              img_type = match[1]
              img_data = match[2]
              
              # Generate filename
              filename = generate_document_filename(formatted_date, doc_type, img_type)
              filepath = File.join(@download_dir, filename)
              
              # Decode and save image
              require 'base64'
              File.open(filepath, 'wb') do |f|
                f.write(Base64.decode64(img_data))
              end
              
              puts "✓ Saved embedded image: #{filename}"
              
              # Record successful download
              record_document_download(doc_id, title_text, doc_date, filename)
              
              return :success
            end
          end
          
        rescue => e
          puts "Could not process view-only document: #{e.message}"
          return :failed
        end
      end
      
    rescue => e
      puts "Error downloading individual document: #{e.message}"
      return :failed
    end
  end
  
  def parse_date_to_filename(date_str)
    # Parse "21 July 2025" to "2025-07-21"
    begin
      date = Date.parse(date_str)
      date.strftime('%Y-%m-%d')
    rescue
      Date.today.strftime('%Y-%m-%d')
    end
  end
  
  def generate_document_filename(date, doc_type, extension)
    # Generate unique filename: YYYY-MM-DD_doctype_uniqueid.ext
    unique_id = SecureRandom.hex(4)
    "#{date}_#{doc_type.downcase}_#{unique_id}.#{extension}"
  end
  
  def wait_for_download_and_rename(target_filename)
    # Wait for download to complete
    download_wait_time = 10
    check_interval = 0.5
    elapsed = 0
    
    original_files = Dir.entries(@download_dir).select { |f| File.file?(File.join(@download_dir, f)) }
    
    while elapsed < download_wait_time
      current_files = Dir.entries(@download_dir).select { |f| File.file?(File.join(@download_dir, f)) }
      new_files = current_files - original_files
      
      # Look for new file that's not a temp file
      new_files.reject! { |f| f.end_with?('.crdownload') || f.end_with?('.tmp') }
      
      if new_files.any?
        # Found new file
        new_file = new_files.first
        old_path = File.join(@download_dir, new_file)
        new_path = File.join(@download_dir, target_filename)
        
        # Rename file
        FileUtils.mv(old_path, new_path)
        puts "✓ Downloaded and renamed to: #{target_filename}"
        return
      end
      
      sleep(check_interval)
      elapsed += check_interval
    end
    
    puts "⚠️  Download may have failed or timed out"
  end
  
  def handle_unavailable_document(title_text, skipped_documents)
    puts "Document is not available through the NHS App"
    
    # Extract comments if available
    comments = ""
    begin
      comment_section = @driver.find_element(css: "div.nhsuk-u-padding-bottom-3")
      if comment_section.text.include?("Comments")
        comment_pre = comment_section.find_element(css: "pre")
        comments = comment_pre.text
        puts "Comments: #{comments}"
      end
    rescue
      # No comments found
    end
    
    # Extract any additional info
    info_text = ""
    begin
      info_div = @driver.find_element(css: "div#documentInfo p")
      info_text = info_div.text
    rescue
      # No additional info
    end
    
    skipped_documents << {
      title: title_text,
      reason: "Not available through NHS App",
      details: comments.empty? ? info_text : comments
    }
  end
  
  def generate_skipped_documents_report(skipped_documents)
    puts "\n" + "="*60
    puts "SKIPPED DOCUMENTS SUMMARY"
    puts "="*60
    puts "Total skipped: #{skipped_documents.length}"
    puts ""
    
    # Group by reason
    by_reason = skipped_documents.group_by { |doc| doc[:reason] }
    
    by_reason.each do |reason, docs|
      puts "\n#{reason} (#{docs.length} documents):"
      puts "-" * 40
      docs.each_with_index do |doc, index|
        puts "#{index + 1}. #{doc[:title]}"
        puts "   Details: #{doc[:details]}" if doc[:details] && !doc[:details].empty?
      end
    end
    
    # Save report to file
    report_path = File.join(@download_dir, "skipped_documents_report.txt")
    File.open(report_path, 'w') do |f|
      f.puts "NHS Records Download - Skipped Documents Report"
      f.puts "Generated: #{DateTime.now}"
      f.puts "="*60
      f.puts "Total skipped: #{skipped_documents.length}"
      f.puts ""
      
      by_reason.each do |reason, docs|
        f.puts "\n#{reason} (#{docs.length} documents):"
        f.puts "-" * 40
        docs.each_with_index do |doc, index|
          f.puts "#{index + 1}. #{doc[:title]}"
          f.puts "   Details: #{doc[:details]}" if doc[:details] && !doc[:details].empty?
        end
      end
    end
    
    puts "\nReport saved to: #{report_path}"
  end
  
  def save_consultations_data(consultations)
    # Save as JSON
    json_path = File.join(@download_dir, "consultations_and_events.json")
    File.open(json_path, 'w') do |f|
      f.puts JSON.pretty_generate(consultations)
    end
    puts "✓ Saved consultations to: #{json_path}"
    
    # Save as CSV
    csv_path = File.join(@download_dir, "consultations_and_events.csv")
    require 'csv'
    
    CSV.open(csv_path, 'w') do |csv|
      # Header row
      csv << ['Date', 'Surgery', 'Surgery Type', 'Staff Name', 'Staff Role', 'Entry Type', 'Entry Details', 'Code']
      
      # Data rows
      consultations.each do |consultation|
        if consultation[:entries].empty?
          # Add consultation with no entries
          csv << [
            consultation[:date],
            consultation[:surgery],
            consultation[:surgery_type],
            consultation[:staff_name],
            consultation[:staff_role],
            '',
            '',
            ''
          ]
        else
          # Add each entry as a separate row
          consultation[:entries].each do |entry|
            csv << [
              consultation[:date],
              consultation[:surgery],
              consultation[:surgery_type],
              consultation[:staff_name],
              consultation[:staff_role],
              entry[:type],
              entry[:details],
              entry[:code]
            ]
          end
        end
      end
    end
    puts "✓ Saved consultations to: #{csv_path}"
    
    # Generate summary statistics
    puts "\nConsultations Summary:"
    puts "- Total consultations: #{consultations.length}"
    
    # Count by date
    dated_consultations = consultations.reject { |c| c[:date] == "Unknown Date" }
    unknown_date_consultations = consultations.select { |c| c[:date] == "Unknown Date" }
    puts "- With known dates: #{dated_consultations.length}"
    puts "- With unknown dates: #{unknown_date_consultations.length}"
    
    # Count entries by type
    entry_types = Hash.new(0)
    consultations.each do |consultation|
      consultation[:entries].each do |entry|
        entry_types[entry[:type]] += 1
      end
    end
    
    if entry_types.any?
      puts "\nEntry types found:"
      entry_types.sort_by { |type, count| -count }.each do |type, count|
        puts "  - #{type}: #{count}"
      end
    end
  end

  def run
    begin
      login
      
      # If test login only, stop here
      if @options[:test_login]
        puts "\n✅ Login test completed successfully!"
        puts "Press Enter to close the browser..."
        gets
        return
      end
      
      # After successful login, navigate to GP records
      if navigate_to_gp_records
        download_records
        puts "Downloads completed successfully!"
      else
        puts "Failed to navigate to GP records"
      end
    rescue => e
      puts "Error: #{e.message}"
      puts e.backtrace
    ensure
      # Save download history one final time
      save_download_history if @download_history && !@options[:test_login]
      @driver.quit if @driver
    end
  end
end

if __FILE__ == $0
  options = {}
  
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"
    
    opts.on("-s", "--sections SECTIONS", Array, "Comma-separated list of sections to download (documents,consultations,test)") do |sections|
      options[:sections] = sections
    end
    
    opts.on("-v", "--verbose", "Enable verbose output for debugging") do
      options[:verbose] = true
    end
    
    opts.on("--skip-details", "Skip downloading individual test result details (faster)") do
      options[:skip_details] = true
    end
    
    opts.on("--test-login", "Test login only (no downloads)") do
      options[:test_login] = true
    end
    
    opts.on("-h", "--help", "Show this help message") do
      puts opts
      puts "\nExamples:"
      puts "  #{$0}                    # Download all sections (default)"
      puts "  #{$0} --test-login       # Test login only"
      puts "  #{$0} -s test            # Download only test results"
      puts "  #{$0} -s docs,consult    # Download documents and consultations"
      puts "  #{$0} -s test -v         # Download test results with verbose output"
      puts "\nAvailable sections:"
      puts "  documents    - GP documents and letters"
      puts "  consultations - Consultations and events"
      puts "  test         - Test results"
      exit
    end
  end.parse!
  
  downloader = NHSRecordsDownloader.new(options)
  downloader.run
end