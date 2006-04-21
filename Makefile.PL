use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile(
			  'NAME'	=> 'POE::Component::Client::NNTP',
			  'PM'      => { 'NNTP.pm' => '$(INST_LIBDIR)/NNTP.pm',
						   },
			  'PREREQ_PM' => {
							  'POE'    => 0.31,
							  'Carp'   => 0,
							  'Socket' => 0,
							  'warnings' => 0,
							 },
			  'VERSION_FROM' => 'NNTP.pm', # finds $VERSION
			  'dist' => { 'COMPRESS' => 'gzip --best' },
			 );

