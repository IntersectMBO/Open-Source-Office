# Script Name

This scripts performs a self-attestation on the owner/repo.e.g. cardano-foundation/cardano-wallet

## Setup

Instructions to install or run.
- Setup
  - set up github api 
  - you will need a token 'pat' and you will need to authenticate 'gh auth login' (you can unset GH_TOKEN if you have many accts)
- Running 
  - clone the repo per below
  -- gh repo clone IntersectMBO/Open-Source-Office
  - confirm repo status 
   - git status 
  - ensure the script has +x executable permissions
  - run the script
    - ./intersect_ost_self_attest.sh input-output-hk/daedalus --out io_da_attest.pdf --days 30
    - the output should include output locations myuserdir and runninghere (for example)
    - output is html, pdf and markdown
     - ==============================================
       [OUTPUT] Working directory : /home/myuserdir/runninghere
       [OUTPUT] HTML report       : /home/myuserdir/runninghere/io_da_attest.html
       [OUTPUT] PDF report        : /home/myuserdir/runninghere/io_da_attest.pdf
       [OUTPUT] Markdown summary  : /home/myuserdir/runninghere/io_da_attest.md
       ==============================================


## Usage

    - ./intersect_ost_self_attest.sh input-output-hk/daedalus --out io_da_attest.pdf --days 30

## License

MIT / Apache-2.0 / etc.
