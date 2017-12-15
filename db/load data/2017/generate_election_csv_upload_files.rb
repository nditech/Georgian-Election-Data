# load the csv file and then download the processed csv file
# the beginning of the file is a list of functions for each election
# after the functions is the code for where the functions are called
# if no argument is passed in, then all elections will be processed
# else just the one election will be processed

require 'csv'
require 'mysql2'

@user = 'root'
@password = 'root'
@db = 'election_data-elections'
@year = '2017'

@initiative_group_merged_name = 'Independent Merged'
@initiative_group_csv_name = 'Initiative Group'

# if there is a local majoritarian election that requiest additional levels,
# then set the param to true so the count includes a majoritarian id field
@is_local_majoritarian = false

# indicate if district/region names need to be added to data
# - if not, the district name will be the district id
@has_region_district_names = true

@common_headers = [
  'shape',
  'common_id',
  'common_name',
  'Total Voter Turnout (#)',
  'Total Voter Turnout (%)',
  'Number of Precincts with Invalid Ballots from 0-1%',
  'Number of Precincts with Invalid Ballots from 1-3%',
  'Number of Precincts with Invalid Ballots from 3-5%',
  'Number of Precincts with Invalid Ballots > 5%',
  'Invalid Ballots (%)',
  'Precincts with More Ballots Than Votes (#)',
  'Precincts with More Ballots Than Votes (%)',
  'More Ballots Than Votes (Average)',
  'More Ballots Than Votes (#)','Precincts with More Votes than Ballots (#)',
  'Precincts with More Votes than Ballots (%)',
  'More Votes than Ballots (Average)',
  'More Votes than Ballots (#)','Average votes per minute (08:00-12:00)',
  'Average votes per minute (12:00-17:00)',
  'Average votes per minute (17:00-20:00)',
  'Number of Precincts with votes per minute > 2 (08:00-12:00)',
  'Number of Precincts with votes per minute > 2 (12:00-17:00)',
  'Number of Precincts with votes per minute > 2 (17:00-20:00)',
  'Number of Precincts with votes per minute > 2',
  'Precincts Reported (#)',
  'Precincts Reported (%)'
]

@client = Mysql2::Client.new(:host => "localhost", :username => @user, password: @password, database: @db)


################################################

# determine whether the parties hash has the independent key
def has_independent_parties?(parties)
  !parties.map{|x| x[:independent]}.uniq.index{|x| x == true}.nil?
end

# truncate the table
def truncate_table(table)
  @client.query("truncate table `#{table}`");
end

# load the csv data into a table
def load_data(table, file, has_independent_parties=false)
  data = CSV.read(file, {quote_char: '"', force_quotes: true} )
  total = data.length
  data.each_with_index do |row, index|
    puts "--> #{index} out of #{total}" if index % 500 == 0
    # skip header
    if index > 0
      values = ""
      row.each_with_index do |value, value_index|
        if value.nil?
          values << 'NULL'
        else
          values << '"' + value + '"'
        end
        if value_index < row.length-1
          values << ","
        end
      end
      if has_independent_parties
        values << ",NULL"
      end
      # puts "insert into `#{table}` values (#{values})"
      @client.query("insert into `#{table}` values (#{values})")
    end
  end
end

# custom queries
def run_custom_queries(table, parties)
  # create sql statement that sums all of the paries
  sql_party_sum = parties.map{|x| "`#{x[:id]} - #{x[:name]}`"}.join(' + ')

  if @has_region_district_names
    # add the region/district names
    @client.query(
      "update `#{table}` as t, region_district_names as rd
      set t.region = rd.region,t.district_name = rd.district_name
      where t.district_id = rd.district_id"
    )
  else
    # set district name = district id
    @client.query(
      "update `#{table}`
      set district_name = district_id"
    )
  end

  # add valid votes
  @client.query(
    "update `#{table}`
    set num_valid_votes = (num_votes-num_invalid_votes)"
  )

  # add logic check values
  @client.query(
    "update `#{table}`
    set logic_check_fail = if(num_valid_votes = (#{sql_party_sum}), 0, 1)"
  )

  @client.query(
    "update `#{table}`
    set logic_check_difference = (num_valid_votes - (#{sql_party_sum}))"
  )

  @client.query(
    "update `#{table}`
    set more_ballots_than_votes_flag = if(num_valid_votes > (#{sql_party_sum}), 1, 0)"
  )

  @client.query(
    "update `#{table}`
    set more_ballots_than_votes = if(num_valid_votes > (#{sql_party_sum}), num_valid_votes - (#{sql_party_sum}), 0)"
  )

  @client.query(
    "update `#{table}`
    set more_votes_than_ballots_flag = if(num_valid_votes < (#{sql_party_sum}), 1, 0)"
  )

  @client.query(
    "update `#{table}`
    set more_votes_than_ballots = if(num_valid_votes < (#{sql_party_sum}), abs(num_valid_votes - (#{sql_party_sum})), 0)"
  )

  # if this election has independent parties, sum up their votes
  if has_independent_parties?(parties)
    ind_parties = parties.select{|x| x[:independent] == true}
    if ind_parties.length > 0
      # use ifnull because mysql does not add numbers if one is a null
      sql_party_sum = ind_parties.map{|x| "ifnull(`#{x[:id]} - #{x[:name]}`,0)"}.join(' + ')

      @client.query(
        "update `#{table}`
        set `#{@initiative_group_merged_name}` = (#{sql_party_sum})"
      )
    end

  end

end

# download the data
def download_data(table, file, parties)
  data = @client.query("select * from `#{table}` where common_id != '' && common_name != ''")
  party_names = parties.select{|x| x[:independent] != true}.map{|x| x[:name]}
  if has_independent_parties?(parties)
    party_names << @initiative_group_csv_name
  end
  header = @common_headers + party_names
  header.flatten!
  CSV.open(file, 'wb') do |csv|
    csv << header

    data.each do |row|
      csv << row.values.map{|x| x.class.to_s == 'BigDecimal' ? x.to_f.round(2) : x}
    end
  end
end

def load_precinct_counts(election)
  sql = "insert into `#{@year} election #{election} - precinct count`
                select region, district_id, "
  if @is_local_majoritarian
    sql << "major_district_id, "
  end
  sql << "count(*) as num_precints
          from `#{@year} election #{election} - raw`
          group by region, district_id"
  if @is_local_majoritarian
    sql << ", major_district_id"
  end

  @client.query(sql)
end


# process an election
def run_processing(election, parties)
  puts "===================="
  puts "> #{election}"

  table_raw = "#{@year} election #{election} - raw"
  table_csv = "#{@year} election #{election} - csv"
  input_csv = "#{@year}_official_#{election.gsub(' ', '_')}.csv"
  output_csv = "upload_#{@year}_official_#{election.gsub(' ', '_')}.csv"

  # truncate the table
  puts "  - truncating"
  truncate_table(table_raw)

  # load the data
  puts "  - loading"
  load_data(table_raw, input_csv, has_independent_parties?(parties))

  # run special scripts
  puts "  - running special scripts"
  run_custom_queries(table_raw, parties)

  # load precinct count data
  # - this needs to be done before downloading so the views get the correct data
  puts "  - loading precinct counts"
  load_precinct_counts(election)

  # download the data
  puts "  - downloading"
  download_data(table_csv, output_csv, parties)

  puts "> done"
  puts "===================="
end

###################################################3
###################################################3
###################################################3
###################################################3

###################################################3

def local_party
  election = 'local party'
  parties = [
    { id: 1, name: "State for the People" },
    { id: 2, name: "European Georgia" },
    { id: 3, name: "Democratic Movement - Free Georgia" },
    { id: 4, name: "United Democratic Movement" },
    { id: 5, name: "United National Movement" },
    { id: 6, name: "Republican party" },
    { id: 7, name: "For United Georgia" },
    { id: 8, name: "Alliance of Patriots" },
    { id: 9, name: "Leftist Alliance" },
    { id: 10, name: "Labour" },
    { id: 11, name: "National Democratic Party of Georgia" },
    { id: 14, name: "Georgian Unity and Development Party" },
    { id: 15, name: "Socialist Workers Party" },
    { id: 17, name: "Georgia" },
    { id: 18, name: "Union of Georgian Traditionalists" },
    { id: 20, name: "National Forum" },
    { id: 23, name: "New Christian Democrats" },
    { id: 27, name: "Unity - New Georgia" },
    { id: 28, name: "Lord Our Righteousness" },
    { id: 29, name: "New Rights" },
    { id: 31, name: "Freedom Party" },
    { id: 34, name: "Mamulishvili" },
    { id: 37, name: "United Communist Party" },
    { id: 38, name: "Party of People" },
    { id: 39, name: "Progressive Democratic Movement" },
    { id: 41, name: "Georgian Dream" }
  ]

  run_processing(election, parties)
end

###################################################3

def local_major
  election = 'local major'
  parties = [
    { id: 2, name: "European Georgia" },
    { id: 3, name: "Democratic Movement - Free Georgia" },
    { id: 5, name: "United National Movement" },
    { id: 6, name: "Republican party" },
    { id: 7, name: "For United Georgia" },
    { id: 8, name: "Alliance of Patriots" },
    { id: 9, name: "Leftist Alliance" },
    { id: 10, name: "Labour" },
    { id: 15, name: "Socialist Workers Party" },
    { id: 17, name: "Georgia" },
    { id: 20, name: "National Forum" },
    { id: 22, name: "Merab Kostava Society" },
    { id: 27, name: "Unity - New Georgia" },
    { id: 28, name: "Lord Our Righteousness" },
    { id: 31, name: "Freedom Party" },
    { id: 34, name: "Mamulishvili" },
    { id: 37, name: "United Communist Party" },
    { id: 38, name: "Party of People" },
    { id: 39, name: "Progressive Democratic Movement" },
    { id: 41, name: "Georgian Dream" },
    { id: 42, name: "Initiative Group", independent: true },
    { id: 43, name: "Initiative Group", independent: true },
    { id: 44, name: "Initiative Group", independent: true },
    { id: 45, name: "Initiative Group", independent: true }
  ]

  @is_local_majoritarian = true
  @has_region_district_names = false

  run_processing(election, parties)
end


###################################################3

def mayor
  election = 'mayor'
  parties = [
    { id: 2, name: "European Georgia" },
    { id: 3, name: "Democratic Movement - Free Georgia" },
    { id: 5, name: "United National Movement" },
    { id: 8, name: "Alliance of Patriots" },
    { id: 10, name: "Labour" },
    { id: 11, name: "National Democratic Party of Georgia" },
    { id: 14, name: "Georgian Unity and Development Party" },
    { id: 17, name: "Georgia" },
    { id: 18, name: "Union of Georgian Traditionalists" },
    { id: 20, name: "National Forum" },
    { id: 23, name: "New Christian Democrats" },
    { id: 27, name: "Unity - New Georgia" },
    { id: 28, name: "Lord Our Righteousness" },
    { id: 38, name: "Party of People" },
    { id: 39, name: "Progressive Democratic Movement" },
    { id: 41, name: "Georgian Dream" },
    { id: 42, name: "Initiative Group", independent: true }
  ]

  run_processing(election, parties)
end

###################################################3

def governor
  election = 'governor'
  parties = [
    { id: 2, name: "European Georgia" },
    { id: 3, name: "Democratic Movement - Free Georgia" },
    { id: 5, name: "United National Movement" },
    { id: 6, name: "Republican party" },
    { id: 7, name: "For United Georgia" },
    { id: 8, name: "Alliance of Patriots" },
    { id: 9, name: "Leftist Alliance" },
    { id: 10, name: "Labour" },
    { id: 17, name: "Georgia" },
    { id: 18, name: "Union of Georgian Traditionalists" },
    { id: 20, name: "National Forum" },
    { id: 23, name: "New Christian Democrats" },
    { id: 27, name: "Unity - New Georgia" },
    { id: 31, name: "Freedom Party" },
    { id: 37, name: "United Communist Party" },
    { id: 38, name: "Party of People" },
    { id: 41, name: "Georgian Dream" },
    { id: 42, name: "Initiative Group", independent: true },
    { id: 43, name: "Initiative Group", independent: true }
  ]

  run_processing(election, parties)
end

###################################################3

def mayor_runoff
  election = 'mayor runoff'
  parties = [
    { id: 5, name: "United National Movement" },
    { id: 41, name: "Georgian Dream" },
  ]

  run_processing(election, parties)
end

###################################################3

def governor_runoff
  election = 'governor runoff'
  parties = [
    { id: 3, name: "Democratic Movement - Free Georgia" },
    { id: 5, name: "United National Movement" },
    { id: 8, name: "Alliance of Patriots" },
    { id: 41, name: "Georgian Dream" },
    { id: 42, name: "Initiative Group", independent: true }
  ]

  run_processing(election, parties)
end


#################################
#################################
#################################

# process the elections
mayor
governor
mayor_runoff
governor_runoff
local_party
local_major #major and no district names
