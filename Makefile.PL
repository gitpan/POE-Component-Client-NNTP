use ExtUtils::MakeMaker;

WriteMakefile(
			  'NAME'	=> 'POE::Component::Client::NNTP',
			  'PREREQ_PM' => {
							  'warnings' => 0,
							  'POE'    => 0.31,
							  'Carp'   => 0,
							  'Socket' => 0,
							  'warnings' => 0,
							 },
			  'VERSION_FROM' => 'lib/POE/Component/Client/NNTP.pm',
			  'dist' => { 'COMPRESS' => 'gzip --best' },
			 );

