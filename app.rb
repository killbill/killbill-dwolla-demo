require 'sinatra'
require 'killbill_client'
require 'dwolla_v2'
require 'uri'

set :kb_url, ENV['KB_URL'] || 'http://127.0.0.1:8080'
set :client_id, ENV['DWOLLA_CLIENT_ID']
set :client_secret, ENV['DWOLLA_CLIENT_SECRET']
set :dwolla_access_token, ENV['DWOLLA_ACCESS_TOKEN']

#
# Kill Bill configuration and helpers
#

KillBillClient.url = settings.kb_url

# Multi-tenancy and RBAC credentials
options = {
    :username => 'admin',
    :password => 'password',
    :api_key => 'bob',
    :api_secret => 'lazar'
}

# Audit log data
user = 'demo'
reason = 'New subscription'
comment = 'Trigger by Sinatra'

def create_kb_account(dwolla_customer_id, user, reason, comment, options)
  account = KillBillClient::Model::Account.new
  account.name = 'John Doe'
  account.currency = 'USD'
  account.external_key = dwolla_customer_id
  account.create(user, reason, comment, options)
end

def create_kb_payment_method(account, funding_source, customer_id, user, reason, comment, options)
  puts "Customer ID: #{customer_id}"
  puts "Funding Source: #{funding_source}"

  pm = KillBillClient::Model::PaymentMethod.new
  pm.account_id = account.account_id
  pm.plugin_name = 'killbill-dwolla'
  pm.plugin_info = {'fundingSource' => funding_source, 'customerId' => customer_id }
  pm.create(true, user, reason, comment, options)
end

def create_subscription(account, user, reason, comment, options)
  subscription = KillBillClient::Model::Subscription.new
  subscription.account_id = account.account_id
  subscription.product_name = 'Sports'
  subscription.product_category = 'BASE'
  subscription.billing_period = 'MONTHLY'
  subscription.price_list = 'DEFAULT'
  subscription.price_overrides = []

  # For the demo to be interesting, override the trial price to be non-zero so we trigger a charge in Dwolla
  override_trial = KillBillClient::Model::PhasePriceOverrideAttributes.new
  override_trial.phase_type = 'TRIAL'
  override_trial.fixed_price = 10.0
  subscription.price_overrides << override_trial

  begin
    # sometime returns an error: "Error locking accountRecordId='***'"
    subscription.create(user, reason, comment, nil, true, options)
  rescue Exception => e
    puts e.message
  end
end

def get_key_from_url(url, path_to_remove)
  uri = URI.parse(url)
  key = uri.path[path_to_remove.length, uri.path.length]
  puts "id #{key}"
  return key
end

#
# Sinatra handlers
#

get '/' do

  puts "client_id = #{settings.client_id}"
  puts "client_secret = #{settings.client_secret}"
  puts "access_token = #{settings.dwolla_access_token}"

  # see dwolla.com/applications for your client id and secret
  $dwolla = DwollaV2::Client.new(id: settings.client_id,
                                 secret: settings.client_secret
  ) do |config|
    config.environment = :sandbox
  end

  # generate a token on dwolla.com/applications
  account_token = $dwolla.tokens.new access_token: settings.dwolla_access_token

  time = Time.now.strftime("%Y%m%d%H%M%S")
  request_body = {
      :firstName => 'Jane',
      :lastName => 'Merchant',
      :email => "customer_#{time}@nemail.net",
      :ipAddress => '99.99.99.99'
  }

  customer = account_token.post "customers", request_body
  customer_url = customer.headers[:location]
  puts "Customer created: #{customer_url}"

  customer_iav = account_token.post "#{customer_url}/iav-token"
  @iav = customer_iav.token
  @customerId = get_key_from_url(customer_url, '/customers/')

  erb :index
end

post '/charge' do
  # Create an account
  account = create_kb_account(@customerId, user, reason, comment, options)

  # Add a payment method associated with the Dwolla funding source
  fundingSourceId = get_key_from_url(params['fundingSource'], '/funding-sources/')
  create_kb_payment_method(account, fundingSourceId, params['customerId'], user, reason, comment, options)

  # Add a subscription
  create_subscription(account, user, reason, comment, options)

  # Retrieve the invoice
  @invoice = account.invoices(true, options).first
  @customerId = params['customerId']

  erb :charge
end

__END__

@@ layout
  <!DOCTYPE html>
  <html>
  <head>
    <script src="https://cdn.dwolla.com/1/dwolla.js"></script>
    <script src="https://code.jquery.com/jquery-3.1.0.js"></script>
  </head>
  <body>
    <%= yield %>
  </body>
  </html>

@@index
  <span class="image"><img src="https://drive.google.com/uc?&amp;id=0Bw8rymjWckBHT3dKd0U3a1RfcUE&amp;w=960&amp;h=480" alt="uc?&amp;id=0Bw8rymjWckBHT3dKd0U3a1RfcUE&amp;w=960&amp;h=480"></span>
  <article>
      <label class="amount">
        <span>Sports car, 30 days trial for only $10.00!</span>
      </label>
    </article>
  <div id="mainContainer">
     <input type="button" id="start" value="Add Bank">
  </div>

  <div id="iavContainer"></div>
  <form action="/charge" method="post" id="form">
    <input type="hidden" name="fundingSource" value = "" />
    <input type="hidden" name="customerId" value=<%= "'#{@customerId}'" %> />
  </form>

  <script type="text/javascript">
      $('#start').click(function() {

        var iavToken = <%= "'#{@iav}'" %>;
        dwolla.configure('uat');
        dwolla.iav.start(iavToken, {
                container: 'iavContainer',
                stylesheets: [
                  'http://fonts.googleapis.com/css?family=Lato&subset=latin,latin-ext',
                  'http://localhost:8080/iav/customStylesheet.css'
                ],
                microDeposits: 'true',
                fallbackToMicroDeposits : 'true'
              }, function(err, res) {
                  if (err) console.log('Error: ' + JSON.stringify(err) + ' -- Response: ' + JSON.stringify(res));
                  var fundingUrl = res._links['funding-source'].href;
                  $('input[name=fundingSource]').val(fundingUrl);
                  $('#form').submit();
                });
        });
    </script>


@@charge
  <h2>Thanks! Here is your invoice:</h2>
  <ul>
    <% @invoice.items.each do |item| %>
      <li><%= "subscription_id=#{item.subscription_id}, amount=#{item.amount}, phase=sports-monthly-trial, start_date=#{item.start_date}" %></li>
    <% end %>
  </ul>
  You can verify the payment at <a href="<%= "https://sandbox-uat.dwolla.com/#/customers/#{@customerId}" %>"><%= "https://sandbox-uat.dwolla.com/#/customers/#{@customerId}" %></a>.

